package dev.enver.lightweight_barcode_scanner

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.PluginRegistry

/**
 * Camera permission, without pulling in a permissions plugin.
 *
 * The scanner needs exactly one permission, so a dependency for it would be
 * more moving parts than the 60 lines it takes to ask directly.
 */
class CameraPermissions : PluginRegistry.RequestPermissionsResultListener {
    private var pending: ((String) -> Unit)? = null

    fun status(context: Context): String =
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            GRANTED
        } else {
            DENIED
        }

    /** Asks the user, or reports the current state when there is no activity. */
    fun request(activity: Activity?, context: Context, onResult: (String) -> Unit) {
        if (status(context) == GRANTED) {
            onResult(GRANTED)
            return
        }
        if (activity == null) {
            // Without an activity there is nothing to show a dialog on; report
            // the state rather than hanging.
            onResult(DENIED)
            return
        }
        if (pending != null) {
            onResult(DENIED)
            return
        }
        pending = onResult
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.CAMERA),
            REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val callback = pending ?: return false
        pending = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        callback(if (granted) GRANTED else DENIED)
        return true
    }

    /**
     * Distinguishes "denied once" from "don't ask again": after a denial the
     * system only offers a rationale while it is still willing to ask.
     */
    fun statusAfterDenial(activity: Activity?): String = when {
        activity == null -> DENIED
        ActivityCompat.shouldShowRequestPermissionRationale(
            activity,
            Manifest.permission.CAMERA,
        ) -> DENIED
        else -> PERMANENTLY_DENIED
    }

    companion object {
        const val GRANTED = "granted"
        const val DENIED = "denied"
        const val PERMANENTLY_DENIED = "permanentlyDenied"
        private const val REQUEST_CODE = 0x1CB5
    }
}
