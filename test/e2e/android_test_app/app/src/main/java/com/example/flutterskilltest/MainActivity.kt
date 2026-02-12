package com.example.flutterskilltest

import android.content.Intent
import android.os.Bundle
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup

class MainActivity : AppCompatActivity() {

    private var counter = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val counterText = findViewById<TextView>(R.id.counter_text)
        val incrementBtn = findViewById<Button>(R.id.increment_btn)
        val decrementBtn = findViewById<Button>(R.id.decrement_btn)
        val editText = findViewById<EditText>(R.id.input_field)
        val submitBtn = findViewById<Button>(R.id.submit_btn)
        val resultText = findViewById<TextView>(R.id.result_text)
        val checkBox = findViewById<CheckBox>(R.id.test_checkbox)
        val detailBtn = findViewById<Button>(R.id.detail_btn)
        val recyclerView = findViewById<RecyclerView>(R.id.item_list)

        counterText.text = "Count: $counter"

        incrementBtn.setOnClickListener {
            counter++
            counterText.text = "Count: $counter"
        }

        decrementBtn.setOnClickListener {
            counter--
            counterText.text = "Count: $counter"
        }

        submitBtn.setOnClickListener {
            resultText.text = "Submitted: ${editText.text}"
        }

        checkBox.setOnCheckedChangeListener { _, isChecked ->
            resultText.text = if (isChecked) "Checkbox: ON" else "Checkbox: OFF"
        }

        detailBtn.setOnClickListener {
            startActivity(Intent(this, DetailActivity::class.java).apply {
                putExtra("counter", counter)
            })
        }

        recyclerView.layoutManager = LinearLayoutManager(this)
        recyclerView.adapter = SimpleAdapter((1..20).map { "Item $it" })
    }

    class SimpleAdapter(private val items: List<String>) :
        RecyclerView.Adapter<SimpleAdapter.VH>() {

        class VH(view: View) : RecyclerView.ViewHolder(view) {
            val text: TextView = view.findViewById(android.R.id.text1)
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
            val view = LayoutInflater.from(parent.context)
                .inflate(android.R.layout.simple_list_item_1, parent, false)
            return VH(view)
        }

        override fun onBindViewHolder(holder: VH, position: Int) {
            holder.text.text = items[position]
            holder.text.contentDescription = "list_item_$position"
        }

        override fun getItemCount() = items.size
    }
}
