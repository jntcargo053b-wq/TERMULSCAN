package com.termulscan.app

import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.termulscan.app/location"
    private lateinit var locationManager: LocationManager

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
        // Cek permission
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

        // 1. Cek last known location (sangat cepat) — tolak jika stale atau tidak akurat
        val maxAgeMillis = 120_000L
        val maxAccuracyMeters = 50f

        fun isUsable(loc: Location?): Boolean {
            if (loc == null) return false
            val ageMillis = if (loc.elapsedRealtimeNanos > 0L) {
                (SystemClock.elapsedRealtimeNanos() - loc.elapsedRealtimeNanos) / 1_000_000L
            } else {
                Long.MAX_VALUE
            }
            return ageMillis <= maxAgeMillis && loc.accuracy <= maxAccuracyMeters
        }

        val gpsLast = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
        val netLast = locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)

        val cachedBest: Location? = listOfNotNull(gpsLast, netLast)
            .filter { isUsable(it) }
            .minByOrNull { it.accuracy }

        if (cachedBest != null) {
            val map = mapOf(
                "lat" to cachedBest.latitude,
                "lng" to cachedBest.longitude,
                "accuracy" to cachedBest.accuracy
            )
            result.success(map)
            return
        }

        // 2. Tidak ada cache – request update dari semua provider yang aktif,
        // pakai fix pertama yang sudah cukup akurat, atau fix terbaik yang
        // sempat diterima sampai timeout (bukan asal fix tercepat).
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        var requested = false
        var resultSent = false
        var bestLocation: Location? = null

        fun sendResult(location: Location) {
            resultSent = true
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
                    "ageMillis" to ageMillis
                )
            )
        }

        val locationListener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (resultSent) return

                if (bestLocation == null || location.accuracy < bestLocation!!.accuracy) {
                    bestLocation = location
                }

                // Fix ini sudah cukup akurat — langsung pakai, tidak perlu tunggu provider lain
                if (location.accuracy <= maxAccuracyMeters) {
                    sendResult(location)
                    try { locationManager.removeUpdates(this) } catch (_: Exception) {}
                }
                // Kalau belum cukup akurat, jangan resolve — tunggu provider lain atau timeout
            }

            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }

        for (provider in providers) {
            if (locationManager.isProviderEnabled(provider)) {
                try {
                    locationManager.requestSingleUpdate(provider, locationListener, Looper.getMainLooper())
                    requested = true
                } catch (_: Exception) {
                    // Provider mungkin tidak support requestSingleUpdate, abaikan
                }
            }
        }

        if (!requested) {
            result.error("NO_PROVIDER", "No location provider enabled", null)
            return
        }

        // 3. Timeout 5 detik – pakai fix terbaik yang sempat diterima (walau
        // di atas ambang akurasi), atau null kalau tidak ada sama sekali.
        Handler(Looper.getMainLooper()).postDelayed({
            if (!resultSent) {
                val fallback = bestLocation
                if (fallback != null) {
                    sendResult(fallback)
                } else {
                    resultSent = true
                    result.success(mapOf(
                        "lat" to null,
                        "lng" to null,
                        "accuracy" to null
                    ))
                }
                try { locationManager.removeUpdates(locationListener) } catch (_: Exception) {}
            }
        }, 5000)
    }
}
