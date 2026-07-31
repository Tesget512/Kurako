package com.alts.kurako

import android.app.PictureInPictureParams
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Rational
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var autoPictureInPicture = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kurako/android/network",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(null)
                }

                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }

                "setAutoPictureInPicture" -> {
                    autoPictureInPicture = call.arguments as? Boolean ?: false
                    configureAutoPictureInPicture()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun configureAutoPictureInPicture() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoPictureInPicture)
            builder.setSeamlessResizeEnabled(true)
        }
        setPictureInPictureParams(builder.build())
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (
            autoPictureInPicture &&
            Build.VERSION.SDK_INT in Build.VERSION_CODES.O until Build.VERSION_CODES.S &&
            !isInPictureInPictureMode
        ) {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .build(),
            )
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock("kurako-smb-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        multicastLock = null
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }
}
