import SwiftUI
import FlutterSkill

struct ContentView: View {
    @State private var count = 0
    @State private var name = ""
    @State private var output = "Ready"

    var body: some View {
        VStack(spacing: 20) {
            Text("E2E Test App")
                .font(.largeTitle)
                .fontWeight(.bold)
                .flutterSkillText("title") { "E2E Test App" }

            HStack(spacing: 16) {
                Button("Say Hello") {
                    output = "Hello clicked!"
                }
                .flutterSkillButton("hello-btn") { [self] in
                    output = "Hello clicked!"
                }

                Button("Count: \(count)") {
                    count += 1
                }
                .flutterSkillButton("count-btn") { [self] in
                    count += 1
                }
            }

            HStack {
                Text("Name:")
                TextField("Enter your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .flutterSkillTextField("name-field", text: $name)

                Button("Greet") {
                    output = "Hello, \(name.isEmpty ? "World" : name)!"
                }
                .flutterSkillButton("greet-btn") { [self] in
                    output = "Hello, \(name.isEmpty ? "World" : name)!"
                }
            }
            .padding(.horizontal)

            Text(output)
                .font(.title2)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(8)
                .flutterSkillText("output") { [self] in output }

            Spacer()

            Text("Flutter Skill iOS SDK Test")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
