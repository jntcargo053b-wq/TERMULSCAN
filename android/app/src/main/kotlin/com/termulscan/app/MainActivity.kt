package com.termulscan.app

import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
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

        // 1. Cek last known location (sangat cepat)
        var bestLocation: Location? = null
        val gpsLast = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
        val netLast = locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)

        bestLocation = gpsLast ?: netLast

        if (bestLocation != null) {
            val map = mapOf(
                "lat" to bestLocation.latitude,
                "lng" to bestLocation.longitude,
                "accuracy" to bestLocation.accuracy
            )
            result.success(map)
            return
        }

        // 2. Tidak ada cache – request single update dari semua provider yang aktif
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        var requested = false
        var resultSent = false

        val locationListener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (!resultSent) {
                    resultSent = true
                    val map = mapOf(
                        "lat" to location.latitude,
                        "lng" to location.longitude,
                        "accuracy" to location.accuracy
                    )
                    result.success(map)
                }
                // Hapus listener setelah berhasil
                providers.forEach { provider ->
                    try { locationManager.removeUpdates(this) } catch (_: Exception) {}
                }
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

        // 3. Timeout 5 detik – jika tidak ada lokasi, kirim null
        Handler(Looper.getMainLooper()).postDelayed({
            if (!resultSent) {
                resultSent = true
                result.success(mapOf(
                    "lat" to null,
                    "lng" to null,
                    "accuracy" to null
                ))
                // Bersihkan listener
                providers.forEach { provider ->
                    try { locationManager.removeUpdates(locationListener) } catch (_: Exception) {}
                }
            }
        }, 5000)
    }
}
