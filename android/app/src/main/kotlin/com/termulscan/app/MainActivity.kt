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

        fun ageMillis(loc: Location): Long {
            if (loc.elapsedRealtimeNanos <= 0L) return Long.MAX_VALUE
            return ((SystemClock.elapsedRealtimeNanos() - loc.elapsedRealtimeNanos) / 1_000_000L)
                .coerceAtLeast(0L)
        }

        fun isUsable(loc: Location?): Boolean {
            if (loc == null) return false
            return ageMillis(loc) <= 10_000L &&
                loc.latitude.isFinite() && loc.longitude.isFinite()
        }

        fun locationMap(loc: Location, isFallback: Boolean): Map<String, Any?> {
            return mapOf(
                "lat" to loc.latitude,
                "lng" to loc.longitude,
                "accuracy" to if (loc.accuracy > 0f) loc.accuracy else null,
                "ageMillis" to ageMillis(loc),
                "provider" to loc.provider,
                "isFallback" to isFallback
            )
        }

        val gpsLast = try {
            locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
        } catch (_: SecurityException) {
            null
        }
        val netLast = try {
            locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
        } catch (_: SecurityException) {
            null
        }

        val cachedCandidates = listOfNotNull(gpsLast, netLast).filter(::isUsable)
        val cachedBest = cachedCandidates.minWithOrNull { a, b ->
            val ageDifference = ageMillis(a) - ageMillis(b)
            if (kotlin.math.abs(ageDifference) > 3_000L) {
                ageDifference.compareTo(0L)
            } else {
                val aAccuracy = if (a.accuracy > 0f) a.accuracy else Float.MAX_VALUE
                val bAccuracy = if (b.accuracy > 0f) b.accuracy else Float.MAX_VALUE
                aAccuracy.compareTo(bAccuracy)
            }
        }

        // A very recent cached fix is fast enough to use immediately.
        if (cachedBest != null && ageMillis(cachedBest) <= 3_000L) {
            result.success(locationMap(cachedBest, false))
            return
        }

        // A 3–10 second cache is only a fallback. Try to obtain a fresh fix
        // first so a moving courier is not stamped with an old position.
        val cachedFallback = cachedBest
        val handler = Handler(Looper.getMainLooper())
        var resultSent = false
        var bestFresh: Location? = null
        var requested = false
        var refinementRunnable: Runnable? = null
        var timeoutRunnable: Runnable? = null

        var locationListener: LocationListener? = null

        fun finish(location: Location?, isFallback: Boolean) {
            if (resultSent) return
            resultSent = true
            refinementRunnable?.let(handler::removeCallbacks)
            timeoutRunnable?.let(handler::removeCallbacks)
            try { locationListener?.let { locationManager.removeUpdates(it) } } catch (_: Exception) {}
            if (location != null) {
                result.success(locationMap(location, isFallback))
            } else {
                result.success(mapOf(
                    "lat" to null,
                    "lng" to null,
                    "accuracy" to null,
                    "ageMillis" to null,
                    "provider" to null,
                    "isFallback" to false
                ))
            }
        }

        locationListener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (resultSent || !location.latitude.isFinite() || !location.longitude.isFinite()) return
                if (ageMillis(location) > 5_000L) return

                val currentBest = bestFresh
                if (currentBest == null) {
                    bestFresh = location
                    // Give the other provider a short opportunity to return a
                    // better/fresher fix without adding a long camera delay.
                    refinementRunnable = Runnable {
                        finish(bestFresh, false)
                    }.also { handler.postDelayed(it, 450L) }
                } else {
                    val ageDifference = ageMillis(location) - ageMillis(currentBest)
                    val locationAccuracy = if (location.accuracy > 0f) location.accuracy else Float.MAX_VALUE
                    val currentAccuracy = if (currentBest.accuracy > 0f) currentBest.accuracy else Float.MAX_VALUE
                    if (kotlin.math.abs(ageDifference) > 1_000L) {
                        if (ageDifference < 0L) bestFresh = location
                    } else if (locationAccuracy < currentAccuracy) {
                        bestFresh = location
                    }
                }
            }

            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }

        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER
        )
        for (provider in providers) {
            try {
                if (locationManager.isProviderEnabled(provider)) {
                    locationManager.requestSingleUpdate(
                        provider, locationListener!!, Looper.getMainLooper()
                    )
                    requested = true
                }
            } catch (_: Exception) {
                // Provider unavailable or permission changed; try the other one.
            }
        }

        if (!requested) {
            if (cachedFallback != null) {
                finish(cachedFallback, true)
            } else {
                result.error("NO_PROVIDER", "No location provider enabled", null)
            }
            return
        }

        val timeoutMillis = if (cachedFallback != null) 2_500L else 3_500L
        timeoutRunnable = Runnable {
            if (bestFresh != null) {
                finish(bestFresh, false)
            } else if (cachedFallback != null) {
                finish(cachedFallback, true)
            } else {
                finish(null, false)
            }
        }.also { handler.postDelayed(it, timeoutMillis) }
    }
}
