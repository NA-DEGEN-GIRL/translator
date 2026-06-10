package com.translator.koja_translator

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.session.MediaSession
import android.media.session.PlaybackState
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
        headsetButtonChannel?.setMethodCallHandler(null)
        headsetButtonChannel = null
        super.onDestroy()
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
