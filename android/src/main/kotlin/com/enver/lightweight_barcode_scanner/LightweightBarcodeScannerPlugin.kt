package com.enver.lightweight_barcode_scanner

import android.app.Activity
import android.content.Context
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

/**
 * Method-channel front end.
 *
 * It owns the scanner sessions and nothing else: camera work lives in
 * [ScannerSession] and decoding lives in the shared C++ core.
 */
class LightweightBarcodeScannerPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var messenger: BinaryMessenger
    private lateinit var textureRegistry: TextureRegistry

    private val permissions = CameraPermissions()
    private val sessions = mutableMapOf<Int, ScannerSession>()
    private var nextSessionId = 1

    private var activityBinding: ActivityPluginBinding? = null
    private val activity: Activity? get() = activityBinding?.activity

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        textureRegistry = binding.textureRegistry
        channel = MethodChannel(messenger, METHOD_CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        releaseAllSessions()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissions)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissions)
        activityBinding = null
        // The activity is going away and with it the surfaces the camera is
        // drawing into. Hold on to nothing.
        releaseAllSessions()
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        try {
            when (call.method) {
                "checkPermission" -> result.success(permissions.status(context))

                "requestPermission" -> permissions.request(activity, context) { status ->
                    result.success(
                        if (status == CameraPermissions.GRANTED) status
                        else permissions.statusAfterDenial(activity),
                    )
                }

                "create" -> {
                    val arguments = call.arguments as? Map<*, *>
                        ?: throw IllegalArgumentException("create requires arguments")
                    val id = nextSessionId++
                    sessions[id] = ScannerSession(
                        id = id,
                        context = context,
                        textureRegistry = textureRegistry,
                        messenger = messenger,
                        configuration = ScannerConfiguration.fromMap(arguments),
                    )
                    result.success(id)
                }

                "start" -> session(call).start { outcome ->
                    outcome.fold(
                        onSuccess = result::success,
                        onFailure = { error ->
                            result.error(
                                "cameraInitializationFailed",
                                error.message ?: "Could not open the camera.",
                                null,
                            )
                        },
                    )
                }

                "pause" -> {
                    session(call).pause()
                    result.success(null)
                }

                "resume" -> {
                    session(call).resume()
                    result.success(null)
                }

                "stop", "dispose" -> {
                    val id = sessionId(call)
                    sessions.remove(id)?.release()
                    result.success(null)
                }

                "setTorch" -> {
                    session(call).setTorch(call.argument<Boolean>("enabled") == true)
                    result.success(null)
                }

                "setZoom" -> {
                    val zoom = call.argument<Double>("zoom")
                        ?: throw IllegalArgumentException("setZoom requires a zoom")
                    session(call).setZoom(zoom.toFloat())
                    result.success(null)
                }

                "setFocusPoint" -> {
                    session(call).setFocusPoint(
                        call.argument<Double>("x")?.toFloat(),
                        call.argument<Double>("y")?.toFloat(),
                    )
                    result.success(null)
                }

                "switchCamera" -> {
                    val facing = call.argument<String>("facing") ?: "back"
                    session(call).switchCamera(facing) { outcome ->
                        outcome.fold(
                            onSuccess = result::success,
                            onFailure = { error ->
                                result.error(
                                    "cameraUnavailable",
                                    error.message ?: "Could not switch cameras.",
                                    null,
                                )
                            },
                        )
                    }
                }

                "setFormats" -> {
                    session(call).setFormats(call.argument<Int>("formats") ?: 0)
                    result.success(null)
                }

                "setScanRegion" -> {
                    session(call).setScanRegion(
                        ScannerConfiguration.scanAreaFrom(
                            call.argument<List<Double>>("scanRegion"),
                        ),
                    )
                    result.success(null)
                }

                "setDuplicateFilter" -> {
                    session(call).setDuplicateFilter(
                        call.argument<Int>("duplicateFilterMillis")?.toLong() ?: 0L,
                    )
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (error: UnsupportedOperationException) {
            result.error("unsupportedOperation", error.message, null)
        } catch (error: IllegalStateException) {
            result.error("invalidState", error.message, null)
        } catch (error: Throwable) {
            result.error("unknown", error.message ?: error.toString(), null)
        }
    }

    private fun sessionId(call: MethodCall): Int =
        call.argument<Int>("sessionId")
            ?: throw IllegalArgumentException("${call.method} requires a sessionId")

    private fun session(call: MethodCall): ScannerSession =
        sessions[sessionId(call)]
            ?: throw IllegalStateException("This scanner session is no longer available.")

    private fun releaseAllSessions() {
        sessions.values.forEach(ScannerSession::release)
        sessions.clear()
    }

    private companion object {
        const val METHOD_CHANNEL = "com.enver.lightweight_barcode_scanner/methods"
    }
}
