package com.termulscan.app

import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.SystemClock
import android.os.StatFs
import android.os.Handler
import android.os.Looper
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
                } else if (call.method == "getStorageInfo") {
                    getStorageInfo(result)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun getStorageInfo(result: Result) {
        val dir = getExternalFilesDir(null)
        if (dir == null) {
            result.error("STORAGE_UNAVAILABLE", "Storage directory unavailable", null)
            return
        }
        try {
            val stat = StatFs(dir.absolutePath)
            result.success(
                mapOf(
                    "availableBytes" to stat.availableBytes,
                    "totalBytes" to stat.totalBytes
                )
            )
        } catch (e: Exception) {
            result.error("STORAGE_CHECK_FAILED", "Unable to query storage", e.message)
        }
    }

    private fun getCurrentLocation(result: Result) {
        val hasFineLocation = checkSelfPermission(
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarseLocation = checkSelfPermission(
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasFineLocation && !hasCoarseLocation) {
            result.error("PERMISSION_DENIED", "Location permission not granted", null)
            return
        }

        fun ageMillis(loc: Location): Long {
            if (loc.elapsedRealtimeNanos <= 0L) return Long.MAX_VALUE
            return ((SystemClock.elapsedRealtimeNanos() - loc.elapsedRealtimeNanos) / 1_000_000L)
                .coerceAtLeast(0L)
        }

        fun isUsable(loc: Location?): Boolean {
            return loc != null &&
                ageMillis(loc) <= 10_000L &&
                loc.latitude.isFinite() && loc.longitude.isFinite()
        }

        fun locationMap(loc: Location, isFallback: Boolean): Map<String, Any?> {
            return mapOf(
                "lat" to loc.latitude,
                "lng" to loc.longitude,
                "accuracy" to if (loc.hasAccuracy() && loc.accuracy > 0f) loc.accuracy else null,
                "ageMillis" to ageMillis(loc),
                "provider" to loc.provider,
                "isFallback" to isFallback
            )
        }

        val gpsLast = try {
            locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
        } catch (_: SecurityException) { null }
        val netLast = try {
            locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
        } catch (_: SecurityException) { null }

        val cachedCandidates = listOfNotNull(gpsLast, netLast).filter(::isUsable)
        val cachedBest = cachedCandidates.minWithOrNull(
            compareBy<Location> { if (it.hasAccuracy() && it.accuracy > 0f) it.accuracy else Float.MAX_VALUE }
                .thenBy { ageMillis(it) }
        )

        // Cache hanya boleh dipakai langsung bila sangat baru DAN akurasinya
        // diketahui. Cache kasar tidak pernah disamarkan sebagai fix presisi.
        if (cachedBest != null &&
            ageMillis(cachedBest) <= 3_000L &&
            cachedBest.hasAccuracy() &&
            cachedBest.accuracy in 0.1f..50f
        ) {
            result.success(locationMap(cachedBest, false))
            return
        }

        val handler = Handler(Looper.getMainLooper())
        var resultSent = false
        var bestFresh: Location? = null
        var refinementRunnable: Runnable? = null
        var timeoutRunnable: Runnable? = null
        var locationListener: LocationListener? = null

        fun finish(location: Location?, isFallback: Boolean) {
            if (resultSent) return
            resultSent = true
            refinementRunnable?.let(handler::removeCallbacks)
            timeoutRunnable?.let(handler::removeCallbacks)
            try {
                locationListener?.let { locationManager.removeUpdates(it) }
            } catch (_: Exception) {}
            if (location != null) {
                result.success(locationMap(location, isFallback))
            } else {
                result.success(mapOf(
                    "lat" to null, "lng" to null, "accuracy" to null,
                    "ageMillis" to null, "provider" to null, "isFallback" to false
                ))
            }
        }

        fun isBetter(candidate: Location, current: Location): Boolean {
            val candidateAge = ageMillis(candidate)
            val currentAge = ageMillis(current)
            if (kotlin.math.abs(candidateAge - currentAge) > 1_000L) {
                return candidateAge < currentAge
            }
            val candidateAccuracy = if (candidate.hasAccuracy() && candidate.accuracy > 0f)
                candidate.accuracy else Float.MAX_VALUE
            val currentAccuracy = if (current.hasAccuracy() && current.accuracy > 0f)
                current.accuracy else Float.MAX_VALUE
            return candidateAccuracy < currentAccuracy
        }

        locationListener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (resultSent || !location.latitude.isFinite() || !location.longitude.isFinite()) return
                if (ageMillis(location) > 5_000L) return

                val current = bestFresh
                if (current == null || isBetter(location, current)) {
                    bestFresh = location
                }

                val best = bestFresh ?: return
                val accuracy = if (best.hasAccuracy() && best.accuracy > 0f)
                    best.accuracy else Float.MAX_VALUE

                // Fix sangat baik: selesaikan segera. Fix cukup baik: beri
                // waktu singkat untuk provider lain memperbaiki hasilnya.
                if (accuracy <= 25f) {
                    finish(best, false)
                } else if (accuracy <= 60f && refinementRunnable == null) {
                    refinementRunnable = Runnable {
                        finish(bestFresh, false)
                    }.also { handler.postDelayed(it, 1_200L) }
                } else if (refinementRunnable == null) {
                    // Fix pertama belum cukup akurat; tetap dengarkan update
                    // berikutnya sampai batas waktu global.
                }
            }

            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }

        var requested = false
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        for (provider in providers) {
            try {
                if (locationManager.isProviderEnabled(provider)) {
                    // Continuous updates diperlukan agar fix awal yang kasar
                    // dapat diperbaiki oleh sampel berikutnya.
                    locationManager.requestLocationUpdates(
                        provider, 750L, 0f, locationListener!!, Looper.getMainLooper()
                    )
                    requested = true
                }
            } catch (_: Exception) {
                // Provider unavailable or permission changed; try the other one.
            }
        }

        if (!requested) {
            if (cachedBest != null) finish(cachedBest, true)
            else result.error("NO_PROVIDER", "No location provider enabled", null)
            return
        }

        timeoutRunnable = Runnable {
            val fresh = bestFresh
            if (fresh != null) {
                finish(fresh, false)
            } else if (cachedBest != null) {
                finish(cachedBest, true)
            } else {
                finish(null, false)
            }
        }.also { handler.postDelayed(it, 7_000L) }
    }
}
