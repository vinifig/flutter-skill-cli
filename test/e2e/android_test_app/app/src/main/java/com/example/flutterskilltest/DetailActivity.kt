package com.example.flutterskilltest

import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class DetailActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_detail)

        val counter = intent.getIntExtra("counter", 0)
        val titleText = findViewById<TextView>(R.id.detail_title)
        val valueText = findViewById<TextView>(R.id.detail_value)
        val backBtn = findViewById<Button>(R.id.back_btn)

        titleText.text = "Detail Page"
        valueText.text = "Counter value: $counter"

        backBtn.setOnClickListener { finish() }
    }
}
