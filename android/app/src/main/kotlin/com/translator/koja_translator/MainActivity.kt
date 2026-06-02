package com.translator.koja_translator

import android.media.AudioTrack
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
