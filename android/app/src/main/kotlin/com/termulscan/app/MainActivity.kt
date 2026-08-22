package com.termulscan.app

import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.termulscan.app/location"
    private lateinit var locationManager: LocationManager

    companion object {
        // Keep the old fast single-fix design. These limits only reject clearly
        // stale/poor fixes; they do not add a multi-sample lock or Kalman loop.
        private const val MAX_LAST_KNOWN_AGE_MS = 20_000L
        private const val TARGET_ACCURACY_METERS = 0f
        private const val MAX_FALLBACK_ACCURACY_METERS = Float.MAX_VALUE
        private const val TIMEOUT_MS = 5_000L
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getLocation") {
                    getCurrentLocation(result)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun getCurrentLocation(result: Result) {
        val hasFineLocation = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarseLocation = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasFineLocation && !hasCoarseLocation) {
            result.error("PERMISSION_DENIED", "Location permission not granted", null)
            return
        }

        // Fast path: use a genuinely recent, good last-known fix.
        // This preserves the old app's speed while preventing a stale 2-minute
        // position from being stamped onto a new POD photo.
        fun isUsable(loc: Location?, maxAgeMs: Long): Boolean {
            if (loc == null) return false
            if (loc.latitude !in -90.0..90.0 || loc.longitude !in -180.0..180.0) {
                return false
            }
            if (loc.elapsedRealtimeNanos > 0L) {
                val ageMillis =
                    (SystemClock.elapsedRealtimeNanos() - loc.elapsedRealtimeNanos) / 1_000_000L
                return ageMillis in 0..maxAgeMs
            }
            // Some Android providers do not expose elapsedRealtime. The
            // coordinates are still usable; do not reject them only for that.
            return true
        }

        val gpsLast = safeLastKnown(LocationManager.GPS_PROVIDER)
        val netLast = safeLastKnown(LocationManager.NETWORK_PROVIDER)

        // Prefer a good recent GPS fix. If none exists, a good network fix is
        // still valid and keeps capture fast.
        val cachedBest = listOfNotNull(gpsLast, netLast)
            .filter { isUsable(it, MAX_LAST_KNOWN_AGE_MS) }
            .minWithOrNull(compareBy<Location> {
                if (it.provider == LocationManager.GPS_PROVIDER) 0 else 1
            }.thenBy {
                if (it.hasAccuracy()) it.accuracy else Float.MAX_VALUE
            })

        if (cachedBest != null) {
            sendResult(result, cachedBest)
            return
        }

        // No good recent cache: request one-shot updates. This is intentionally
        // lightweight — no rolling window, Kalman filter, or repeated polling.
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER
        )

        var requested = false
        var resultSent = false
        var bestLocation: Location? = null
        val handler = Handler(Looper.getMainLooper())

        fun cleanup(listener: LocationListener) {
            try { locationManager.removeUpdates(listener) } catch (_: Exception) {}
            handler.removeCallbacksAndMessages(null)
        }

        val locationListener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (resultSent || !location.hasAccuracy()) return

                if (bestLocation == null || location.accuracy < bestLocation!!.accuracy) {
                    bestLocation = location
                }

                // Legacy-light behavior: a valid coordinate is enough.
                // Accuracy is returned as metadata and never blocks capture.
                resultSent = true
                sendResult(result, location)
                cleanup(this)
            }

            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }

        for (provider in providers) {
            if (!locationManager.isProviderEnabled(provider)) continue
            try {
                locationManager.requestSingleUpdate(
                    provider,
                    locationListener,
                    Looper.getMainLooper()
                )
                requested = true
            } catch (_: SecurityException) {
                // Permission can change between the check and request.
            } catch (_: Exception) {
                // Provider may not support a one-shot request.
            }
        }

        if (!requested) {
            result.error("NO_PROVIDER", "No location provider enabled", null)
            return
        }

        handler.postDelayed({
            if (resultSent) return@postDelayed
            resultSent = true

            // Legacy-light fallback: if a provider produced any coordinate,
            // return it. Accuracy is metadata only.
            val fallback = bestLocation
            if (fallback != null) {
                sendResult(result, fallback)
            } else {
                result.success(mapOf(
                    "lat" to null,
                    "lng" to null,
                    "accuracy" to null
                ))
            }

            try { locationManager.removeUpdates(locationListener) } catch (_: Exception) {}
        }, TIMEOUT_MS)
    }

    private fun safeLastKnown(provider: String): Location? {
        return try {
            if (locationManager.isProviderEnabled(provider)) {
                locationManager.getLastKnownLocation(provider)
            } else null
        } catch (_: SecurityException) {
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun sendResult(result: Result, location: Location) {
        val ageMillis = if (location.elapsedRealtimeNanos > 0L) {
            (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000L
        } else {
            -1L
        }
        result.success(
            mapOf(
                "lat" to location.latitude,
                "lng" to location.longitude,
                "accuracy" to location.accuracy,
                "ageMillis" to ageMillis,
                "provider" to (location.provider ?: "unknown")
            )
        )
    }
}
