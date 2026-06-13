package com.translator.koja_translator

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var headsetButtonChannel: MethodChannel? = null
    private var headsetMediaSession: MediaSession? = null
    private var headsetSilenceTrack: AudioTrack? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val releaseSilenceRunnable = Runnable { releaseHeadsetSilenceTrack() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "koja_translator/audio_balance"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setStereoPan" -> {
                    val pan = (call.argument<Double>("pan") ?: 0.0).coerceIn(-1.0, 1.0)
                    result.success(applyWebRtcStereoPan(pan))
                }
                "pcmStart" -> {
                    val rate = call.argument<Int>("sampleRate") ?: 24000
                    val voiceComm = call.argument<Boolean>("voiceComm") ?: false
                    result.success(pcmStart(rate, voiceComm))
                }
                "pcmWrite" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes != null) pcmWrite(bytes)
                    result.success(null)
                }
                "pcmStop" -> {
                    pcmStop()
                    result.success(null)
                }
                "pcmSetPan" -> {
                    pcmSetPan((call.argument<Double>("pan") ?: 0.0))
                    result.success(null)
                }
                "isHeadsetConnected" -> {
                    result.success(isHeadsetConnected())
                }
                "setAudioMode" -> {
                    // 0=NORMAL(스테레오 출력), 3=IN_COMMUNICATION(이어폰 마이크/양방향)
                    setAudioMode(call.argument<Int>("mode") ?: 0)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        headsetButtonChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "koja_translator/headset_media_buttons"
        )
        headsetButtonChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    startHeadsetMediaSession()
                    result.success(true)
                }
                "stopListening" -> {
                    stopHeadsetMediaSession()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        stopHeadsetMediaSession()
        pcmStop()
        headsetButtonChannel?.setMethodCallHandler(null)
        headsetButtonChannel = null
        super.onDestroy()
    }

    // --- 저지연 PCM 스트리밍 재생 (실시간 통역 번역 음성) -------------------
    // 웹의 gapless Web Audio에 대응. raw AudioTrack(MODE_STREAM)은 오디오 포커스를
    // 요청하지 않아 동시에 도는 record(VOICE_COMMUNICATION) 마이크 캡처와 공존한다.
    // 입력은 mono PCM16 → STEREO로 복제하며 팬 게인을 데이터에 직접 곱해 좌우 분리.
    private var pcmTrack: AudioTrack? = null
    private var pcmThread: Thread? = null
    private val pcmQueue = java.util.concurrent.LinkedBlockingQueue<ByteArray>()
    @Volatile private var pcmRunning = false
    @Volatile private var pcmLeft = 1f
    @Volatile private var pcmRight = 1f

    @Suppress("DEPRECATION")
    private fun pcmStart(sampleRate: Int, voiceComm: Boolean = false): Boolean {
        pcmStop()
        // 통신(voiceComm) 출력은 mono 트랙 + mono 데이터 — LE Audio conversational은
        // mono 전용이라 stereo 출력은 양방향(마이크)을 깨뜨린다(검증됨). 미디어 출력은
        // stereo 트랙 + monoToStereo(팬 적용)로 L/R.
        val channelMask = if (voiceComm) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val frameBytes = if (voiceComm) 2 else 4
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        // jitter 흡수용 넉넉한 버퍼(~300ms)와 시작 prebuffer(~90ms). play()를
        // 데이터 없이 먼저 호출하면 시작 underrun으로 첫 음절이 뭉개진다(고오온).
        val bufSize = maxOf(
            if (minBuf > 0) minBuf * 4 else 0,
            sampleRate * frameBytes * 300 / 1000
        )
        val prebufferBytes = sampleRate * frameBytes * 90 / 1000
        // 통신모드(이어폰 마이크)에선 출력도 VOICE_COMMUNICATION이라야 버즈
        // 통화 채널로 나간다. USAGE_MEDIA는 통신모드에서 버즈로 안 감(무음).
        val usage = if (voiceComm) {
            AudioAttributes.USAGE_VOICE_COMMUNICATION
        } else {
            AudioAttributes.USAGE_MEDIA
        }
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(usage)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelMask)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufSize)
                .build()
        } catch (e: Throwable) {
            Log.d("KojaPcmStream", "Unable to create stream track", e)
            return false
        }
        return try {
            // 팬은 monoToStereo에서 데이터에 직접 적용(setStereoVolume 미사용).
            // play()는 데이터를 prebuffer한 뒤 writer 스레드에서 호출(시작 underrun 방지).
            pcmTrack = track
            pcmRunning = true
            pcmQueue.clear()
            val thread = Thread {
                var started = false
                var written = 0
                var firstAt = 0L
                fun startIfNeeded() {
                    if (!started) {
                        track.runCatching { play() }
                        started = true
                    }
                }
                while (pcmRunning) {
                    val chunk = try {
                        pcmQueue.poll(50, java.util.concurrent.TimeUnit.MILLISECONDS)
                    } catch (e: InterruptedException) {
                        break
                    }
                    if (chunk == null) {
                        // 큐가 비고 아직 재생 전이면(짧은 발화) 가진 것부터 재생.
                        if (written > 0) startIfNeeded()
                        continue
                    }
                    if (firstAt == 0L) firstAt = SystemClock.elapsedRealtime()
                    // voiceComm(mono)면 그대로, 미디어면 stereo 변환(팬 적용).
                    val data = if (voiceComm) chunk else monoToStereo(chunk)
                    var off = 0
                    while (off < data.size && pcmRunning) {
                        val n = try {
                            track.write(data, off, data.size - off)
                        } catch (e: Throwable) {
                            -1
                        }
                        if (n <= 0) break
                        off += n
                    }
                    written += data.size
                    // prebuffer 채워졌거나 150ms 경과 시 재생 시작(짧은 발화 대비).
                    if (!started &&
                        (written >= prebufferBytes ||
                            SystemClock.elapsedRealtime() - firstAt >= 150)
                    ) {
                        startIfNeeded()
                    }
                }
            }
            thread.isDaemon = true
            pcmThread = thread
            thread.start()
            true
        } catch (e: Throwable) {
            Log.d("KojaPcmStream", "Unable to start stream track", e)
            track.runCatching { release() }
            pcmTrack = null
            pcmRunning = false
            false
        }
    }

    // mono PCM16 → stereo. 팬 게인(pcmLeft/pcmRight)을 데이터에 직접 곱해
    // 좌우 분리(이어폰 공유). setStereoVolume(deprecated)은 일부 기기에서 무시됨.
    private fun monoToStereo(mono: ByteArray): ByteArray {
        val gl = pcmLeft
        val gr = pcmRight
        val out = ByteArray(mono.size * 2)
        var i = 0
        var o = 0
        while (i + 1 < mono.size) {
            val s = (mono[i].toInt() and 0xFF) or (mono[i + 1].toInt() shl 8) // s16le
            val l = (s * gl).toInt().coerceIn(-32768, 32767)
            val r = (s * gr).toInt().coerceIn(-32768, 32767)
            out[o++] = (l and 0xFF).toByte(); out[o++] = ((l shr 8) and 0xFF).toByte() // L
            out[o++] = (r and 0xFF).toByte(); out[o++] = ((r shr 8) and 0xFF).toByte() // R
            i += 2
        }
        return out
    }

    private fun pcmWrite(bytes: ByteArray) {
        if (!pcmRunning) return
        pcmQueue.offer(bytes)
    }

    private fun pcmStop() {
        pcmRunning = false
        pcmThread?.runCatching {
            interrupt()
            join(200)
        }
        pcmThread = null
        pcmQueue.clear()
        pcmTrack?.runCatching {
            if (playState == AudioTrack.PLAYSTATE_PLAYING) stop()
            flush()
            release()
        }
        pcmTrack = null
    }

    // BT 동적 전환(실험): 발화 땐 IN_COMMUNICATION(이어폰 마이크), 출력 땐
    // NORMAL(스테레오 출력)로 오디오 모드를 순간 전환한다. 전환 지연은 기기/BT 스택
    // 의존이라 사용자가 직접 체감 테스트.
    // 우리가 통신 디바이스를 설정했는지 추적 — 설정한 경우에만 해제해서
    // L/R(일반모드) 미디어 라우팅(A2DP 스테레오)을 절대 건드리지 않는다.
    @Volatile private var commDeviceSet = false

    private fun setAudioMode(mode: Int) {
        try {
            val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
            am.mode = mode
            // 통신 디바이스 조작은 통신모드(이어폰 마이크)에서만. 통신모드에선 출력/
            // 입력을 BT 헤드셋으로 명시 라우팅(안 하면 폰 스피커로 샘). 그 외(L/R
            // 미디어)에선 우리가 설정한 적 있을 때만 해제 — 그 외엔 절대 안 건드림.
            if (Build.VERSION.SDK_INT >= 31) {
                if (mode == android.media.AudioManager.MODE_IN_COMMUNICATION) {
                    val devs = am.availableCommunicationDevices
                    Log.d(
                        "KojaCommDev",
                        "available=[${devs.joinToString { "${it.type}" }}] " +
                            "cur=${am.communicationDevice?.type}"
                    )
                    // 우선순위 선택: LE Audio 헤드셋(26) > BLE 스피커(27) > 유선(3) >
                    // USB(22) > 클래식 SCO(7). SCO는 mono 저음질이라 최후. 버즈3 Pro는
                    // BLE_HEADSET(26)으로 잡아야 마이크·출력이 LE Audio 버즈로 간다.
                    val priority = intArrayOf(
                        android.media.AudioDeviceInfo.TYPE_BLE_HEADSET,
                        android.media.AudioDeviceInfo.TYPE_BLE_SPEAKER,
                        android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        android.media.AudioDeviceInfo.TYPE_USB_HEADSET,
                        android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                    )
                    var bt: android.media.AudioDeviceInfo? = null
                    for (t in priority) {
                        bt = devs.firstOrNull { it.type == t }
                        if (bt != null) break
                    }
                    if (bt != null) {
                        val ok = am.setCommunicationDevice(bt)
                        commDeviceSet = ok
                        Log.d("KojaCommDev", "setCommunicationDevice type=${bt.type} ok=$ok")
                    } else {
                        Log.d("KojaCommDev", "no external comm device → fallback builtin")
                    }
                } else if (commDeviceSet) {
                    am.clearCommunicationDevice()
                    commDeviceSet = false
                    Log.d("KojaCommDev", "clearCommunicationDevice")
                }
            }
            Log.d("KojaAudioBalance", "setAudioMode mode=$mode")
        } catch (e: Throwable) {
            Log.d("KojaAudioBalance", "setAudioMode failed", e)
        }
    }

    // 헤드셋(유선/BT/USB) 출력이 연결돼 있으면 true. 스피커 출력 판정용
    // (스피커일 때만 번역 음성 재생 중 마이크를 막아 에코 방지).
    private fun isHeadsetConnected(): Boolean {
        return try {
            val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
            val devices = am.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
            val headsetTypes = setOf(
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                android.media.AudioDeviceInfo.TYPE_BLE_HEADSET,
                android.media.AudioDeviceInfo.TYPE_USB_HEADSET,
            )
            devices.any { it.type in headsetTypes }
        } catch (e: Throwable) {
            Log.d("KojaAudioBalance", "isHeadsetConnected failed", e)
            false
        }
    }

    // 팬 게인만 갱신 — 다음 monoToStereo부터 데이터에 반영된다.
    private fun pcmSetPan(pan: Double) {
        val p = pan.coerceIn(-1.0, 1.0)
        if (p < 0) {
            pcmLeft = 1f
            pcmRight = (1.0 + p).toFloat()
        } else {
            pcmLeft = (1.0 - p).toFloat()
            pcmRight = 1f
        }
        Log.d("KojaPcmStream", "pcmSetPan pan=$p L=$pcmLeft R=$pcmRight")
    }

    private fun startHeadsetMediaSession() {
        val existing = headsetMediaSession
        if (existing != null) {
            existing.isActive = true
            playSilenceToClaimMediaButtons()
            return
        }

        val session = MediaSession(this, "KojaHeadsetButtons")
        session.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                val event = mediaButtonIntent.getParcelableExtra<KeyEvent>(
                    Intent.EXTRA_KEY_EVENT
                ) ?: return false
                if (event.action != KeyEvent.ACTION_UP || event.repeatCount > 0) {
                    return true
                }
                return dispatchHeadsetKey(event.keyCode)
            }

            override fun onPlay() {
                dispatchHeadsetAction("play_pause", KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            }

            override fun onPause() {
                dispatchHeadsetAction("play_pause", KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            }

            override fun onSkipToNext() {
                dispatchHeadsetAction("next", KeyEvent.KEYCODE_MEDIA_NEXT)
            }

            override fun onSkipToPrevious() {
                dispatchHeadsetAction("previous", KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            }
        })

        val state = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS
            )
            .setState(
                PlaybackState.STATE_PLAYING,
                PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                1f,
                SystemClock.elapsedRealtime()
            )
            .build()
        session.setPlaybackState(state)
        session.isActive = true
        headsetMediaSession = session
        playSilenceToClaimMediaButtons()
    }

    private fun stopHeadsetMediaSession() {
        releaseHeadsetSilenceTrack()
        headsetMediaSession?.let { session ->
            session.isActive = false
            session.setCallback(null)
            session.release()
        }
        headsetMediaSession = null
    }

    // Android 8+은 "가장 최근에 오디오를 재생한 UID"의 세션에만 미디어 버튼을
    // 라우팅한다(MediaSessionStack). 세션 활성화만으로는 후보조차 되지 않으므로
    // USAGE_MEDIA 무음을 짧게 재생해 이 앱 UID를 라우팅 목록 맨 앞에 올린다.
    private fun playSilenceToClaimMediaButtons() {
        releaseHeadsetSilenceTrack()
        val sampleRate = 48000
        val durationMs = 700
        val buf = ByteArray(sampleRate * durationMs / 1000 * 2)
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(buf.size)
                .build()
        } catch (e: Throwable) {
            Log.d("KojaHeadsetButtons", "Unable to create silence track", e)
            return
        }
        try {
            track.write(buf, 0, buf.size)
            // setVolume(0f) 금지: Android 14+는 음소거된 STARTED 플레이어를
            // 활성 재생으로 집계하지 않아 라우팅 등록이 되지 않는다.
            track.play()
            headsetSilenceTrack = track
            mainHandler.postDelayed(releaseSilenceRunnable, durationMs + 300L)
        } catch (e: Throwable) {
            Log.d("KojaHeadsetButtons", "Unable to play silence track", e)
            track.runCatching { release() }
        }
    }

    private fun releaseHeadsetSilenceTrack() {
        mainHandler.removeCallbacks(releaseSilenceRunnable)
        headsetSilenceTrack?.runCatching {
            stop()
            release()
        }
        headsetSilenceTrack = null
    }

    private fun dispatchHeadsetKey(keyCode: Int): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                dispatchHeadsetAction("play_pause", keyCode)
                true
            }
            KeyEvent.KEYCODE_MEDIA_NEXT -> {
                dispatchHeadsetAction("next", keyCode)
                true
            }
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                dispatchHeadsetAction("previous", keyCode)
                true
            }
            else -> false
        }
    }

    private fun dispatchHeadsetAction(action: String, keyCode: Int) {
        headsetButtonChannel?.invokeMethod(
            "onMediaButton",
            mapOf(
                "action" to action,
                "keyCode" to keyCode,
                "timestampMs" to System.currentTimeMillis()
            )
        )
    }

    @Suppress("DEPRECATION")
    private fun applyWebRtcStereoPan(pan: Double): Boolean {
        val left: Float
        val right: Float
        if (pan < 0) {
            left = 1f
            right = (1.0 + pan).coerceIn(0.0, 1.0).toFloat()
        } else {
            left = (1.0 - pan).coerceIn(0.0, 1.0).toFloat()
            right = 1f
        }

        return try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton ?: return false
            val handlerField = FlutterWebRTCPlugin::class.java
                .getDeclaredField("methodCallHandler")
            handlerField.isAccessible = true
            val handler = handlerField.get(plugin) ?: return false
            val admField = handler.javaClass.getDeclaredField("audioDeviceModule")
            admField.isAccessible = true
            val adm = admField.get(handler) ?: return false
            val outputField = adm.javaClass.getDeclaredField("audioOutput")
            outputField.isAccessible = true
            val output = outputField.get(adm) ?: return false
            val trackField = output.javaClass.getDeclaredField("audioTrack")
            trackField.isAccessible = true
            val track = trackField.get(output) as? AudioTrack ?: return false
            track.setStereoVolume(left, right)
            true
        } catch (e: Throwable) {
            Log.d("KojaAudioBalance", "Unable to apply stereo pan", e)
            false
        }
    }
}
