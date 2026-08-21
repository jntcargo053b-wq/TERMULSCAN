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
        private const val TARGET_ACCURACY_METERS = 20f
        private const val MAX_FALLBACK_ACCURACY_METERS = 30f
        private const val MAX_LAST_KNOWN_AGE_MS = 20_000L
        private const val LOCK_SAMPLES = 5
        private const val MIN_STABLE_SAMPLES = 3
        private const val STABILITY_RADIUS_METERS = 15f
        private const val TIMEOUT_MS = 7_000L
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

        // Capture/POD tidak menggunakan cache Flutter/native. Last-known hanya
        // fallback terakhir dan harus benar-benar baru serta cukup akurat.
        val gpsLast = safeLastKnown(LocationManager.GPS_PROVIDER)
        val netLast = safeLastKnown(LocationManager.NETWORK_PROVIDER)
        val cachedBest = listOfNotNull(gpsLast, netLast)
            .filter { isFreshAndAccurate(it, MAX_LAST_KNOWN_AGE_MS, MAX_FALLBACK_ACCURACY_METERS) }
            .minByOrNull { providerScore(it) }

        // Jangan langsung menerima last-known yang masih bisa stale. Jika ada,
        // gunakan hanya sebagai fast fallback sementara tetap mencoba fresh fix.
        // Untuk POD, fresh GNSS diberi prioritas.
        val samples = mutableListOf<Location>()
        var resultSent = false
        var requested = false
        val handler = Handler(Looper.getMainLooper())

        fun cleanup(listener: LocationListener) {
            try { locationManager.removeUpdates(listener) } catch (_: Exception) {}
            handler.removeCallbacksAndMessages(null)
        }

        fun send(location: Location, locked: Boolean, fallback: Boolean) {
            if (resultSent) return
            resultSent = true
            val ageMillis = if (location.elapsedRealtimeNanos > 0L) {
                ((SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000L).coerceAtLeast(0L)
            } else {
                -1L
            }
            result.success(mapOf(
                "lat" to location.latitude,
                "lng" to location.longitude,
                "accuracy" to location.accuracy,
                "ageMillis" to ageMillis,
                "provider" to (location.provider ?: "unknown"),
                "locked" to locked,
                "fallback" to fallback
            ))
        }

        fun chooseBest(): Location? {
            val fresh = samples.filter {
                isFreshAndAccurate(it, 3_000L, MAX_FALLBACK_ACCURACY_METERS)
            }
            if (fresh.isEmpty()) return null

            // GNSS/GPS selalu diprioritaskan jika kualitasnya sebanding.
            return fresh.minByOrNull { providerScore(it) }
        }

        fun hasStableCluster(): Location? {
            val qualified = samples.filter { it.accuracy <= TARGET_ACCURACY_METERS }
            if (qualified.size < MIN_STABLE_SAMPLES) return null

            val recent = qualified.takeLast(MIN_STABLE_SAMPLES)
            val center = recent.first()
            val stable = recent.all { distanceMeters(center, it) <= STABILITY_RADIUS_METERS }
            if (!stable) return null

            // Weighted centroid: sample dengan accuracy lebih baik punya bobot lebih besar.
            var sumLat = 0.0
            var sumLng = 0.0
            var sumWeight = 0.0
            for (loc in recent) {
                val sigma = loc.accuracy.coerceAtLeast(3f).toDouble()
                val weight = 1.0 / (sigma * sigma)
                sumLat += loc.latitude * weight
                sumLng += loc.longitude * weight
                sumWeight += weight
            }
            val lat = sumLat / sumWeight
            val lng = sumLng / sumWeight
            val locked = Location(center).apply {
                latitude = lat
                longitude = lng
                accuracy = recent.map { it.accuracy }.minOrNull() ?: center.accuracy
                provider = "locked"
            }
            return locked
        }

        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (resultSent) return
                if (!location.hasAccuracy()) return

                // Ignore very old callbacks and wildly inaccurate fixes.
                if (!isFreshAndAccurate(location, 3_000L, 50f)) return

                samples.add(location)
                if (samples.size > LOCK_SAMPLES) samples.removeAt(0)

                val locked = hasStableCluster()
                if (locked != null) {
                    send(locked, locked = true, fallback = false)
                    cleanup(this)
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
            if (!locationManager.isProviderEnabled(provider)) continue
            try {
                locationManager.requestLocationUpdates(
                    provider,
                    700L,
                    0f,
                    listener,
                    Looper.getMainLooper()
                )
                requested = true
            } catch (_: SecurityException) {
                // Permission may have changed between the check and request.
            } catch (_: Exception) {
                // Provider may be unavailable on this device.
            }
        }

        if (!requested) {
            result.error("NO_PROVIDER", "No location provider enabled", null)
            return
        }

        handler.postDelayed({
            if (resultSent) return@postDelayed

            val best = chooseBest()
            if (best != null && best.accuracy <= MAX_FALLBACK_ACCURACY_METERS) {
                // If a fresh GNSS/network fix exists but did not converge, expose
                // it explicitly as fallback so Flutter can decide whether to accept.
                send(best, locked = false, fallback = true)
            } else if (cachedBest != null) {
                send(cachedBest, locked = false, fallback = true)
            } else {
                resultSent = true
                result.success(mapOf(
                    "lat" to null,
                    "lng" to null,
                    "accuracy" to null,
                    "locked" to false,
                    "fallback" to false
                ))
            }
            cleanup(listener)
        }, TIMEOUT_MS)
    }

    private fun safeLastKnown(provider: String): Location? {
        return try {
            if (locationManager.isProviderEnabled(provider)) {
                locationManager.getLastKnownLocation(provider)
            } else null
        } catch (_: Exception) {
            null
        }
    }

    private fun isFreshAndAccurate(location: Location, maxAgeMs: Long, maxAccuracy: Float): Boolean {
        if (!location.hasAccuracy() || location.accuracy > maxAccuracy) return false
        if (location.elapsedRealtimeNanos <= 0L) return false
        val age = (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000L
        return age in 0..maxAgeMs
    }

    private fun providerScore(location: Location): Double {
        val providerPenalty = if (location.provider == LocationManager.GPS_PROVIDER) 0.0 else 100.0
        return location.accuracy.toDouble() + providerPenalty
    }

    private fun distanceMeters(a: Location, b: Location): Float {
        val out = FloatArray(1)
        Location.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude, out)
        return out[0]
    }
}
