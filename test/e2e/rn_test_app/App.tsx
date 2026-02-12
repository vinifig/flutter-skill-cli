import React, { useState } from 'react';
import {
  View,
  Text,
  Button,
  TextInput,
  FlatList,
  Switch,
  ScrollView,
  StyleSheet,
  TouchableOpacity,
} from 'react-native';

type Screen = 'home' | 'detail' | 'form';

const ITEMS = Array.from({ length: 20 }, (_, i) => ({ id: String(i), title: `Item ${i + 1}` }));

export default function App() {
  const [screen, setScreen] = useState<Screen>('home');
  const [counter, setCounter] = useState(0);
  const [inputText, setInputText] = useState('');
  const [submitted, setSubmitted] = useState('');
  const [switchOn, setSwitchOn] = useState(false);

  // Form state
  const [formName, setFormName] = useState('');
  const [formEmail, setFormEmail] = useState('');
  const [formResult, setFormResult] = useState('');

  if (screen === 'detail') {
    return (
      <View style={styles.container}>
        <Text style={styles.title} accessibilityLabel="detail_title">Detail Page</Text>
        <Text style={styles.value} accessibilityLabel="detail_value">Counter: {counter}</Text>
        <Button title="Go Back" onPress={() => setScreen('home')} accessibilityLabel="back_btn" />
      </View>
    );
  }

  if (screen === 'form') {
    return (
      <ScrollView style={styles.scroll} contentContainerStyle={styles.container}>
        <Text style={styles.title}>Form</Text>
        <TextInput
          style={styles.input}
          placeholder="Name"
          value={formName}
          onChangeText={setFormName}
          accessibilityLabel="form_name"
        />
        <TextInput
          style={styles.input}
          placeholder="Email"
          value={formEmail}
          onChangeText={setFormEmail}
          accessibilityLabel="form_email"
          keyboardType="email-address"
        />
        <Button
          title="Submit Form"
          onPress={() => setFormResult(`Name: ${formName}, Email: ${formEmail}`)}
          accessibilityLabel="form_submit"
        />
        {formResult ? <Text style={styles.result} accessibilityLabel="form_result">{formResult}</Text> : null}
        <View style={{ marginTop: 16 }}>
          <Button title="Go Back" onPress={() => setScreen('home')} accessibilityLabel="form_back_btn" />
        </View>
      </ScrollView>
    );
  }

  return (
    <ScrollView style={styles.scroll} contentContainerStyle={styles.container}>
      <Text style={styles.title} accessibilityLabel="counter_text">Count: {counter}</Text>

      <View style={styles.row}>
        <Button title="+" onPress={() => setCounter(c => c + 1)} accessibilityLabel="increment_btn" />
        <View style={{ width: 16 }} />
        <Button title="-" onPress={() => setCounter(c => c - 1)} accessibilityLabel="decrement_btn" />
      </View>

      <TextInput
        style={styles.input}
        placeholder="Enter text here"
        value={inputText}
        onChangeText={setInputText}
        accessibilityLabel="input_field"
      />

      <Button title="Submit" onPress={() => setSubmitted(`Submitted: ${inputText}`)} accessibilityLabel="submit_btn" />

      {submitted ? <Text style={styles.result} accessibilityLabel="result_text">{submitted}</Text> : null}

      <View style={styles.switchRow}>
        <Text>Toggle Switch</Text>
        <Switch
          value={switchOn}
          onValueChange={setSwitchOn}
          accessibilityLabel="test_switch"
        />
        <Text accessibilityLabel="switch_status">{switchOn ? 'ON' : 'OFF'}</Text>
      </View>

      <View style={styles.row}>
        <Button title="Go to Detail" onPress={() => setScreen('detail')} accessibilityLabel="detail_btn" />
        <View style={{ width: 16 }} />
        <Button title="Go to Form" onPress={() => setScreen('form')} accessibilityLabel="form_btn" />
      </View>

      <FlatList
        data={ITEMS}
        keyExtractor={item => item.id}
        renderItem={({ item }) => (
          <TouchableOpacity style={styles.listItem} accessibilityLabel={`list_item_${item.id}`}>
            <Text>{item.title}</Text>
          </TouchableOpacity>
        )}
        scrollEnabled={false}
        style={{ marginTop: 16 }}
        accessibilityLabel="item_list"
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1 },
  container: { padding: 16, alignItems: 'center' },
  title: { fontSize: 24, fontWeight: 'bold', marginBottom: 16 },
  value: { fontSize: 20, marginBottom: 16 },
  result: { fontSize: 16, marginTop: 8, color: '#333' },
  row: { flexDirection: 'row', alignItems: 'center', marginVertical: 8 },
  switchRow: { flexDirection: 'row', alignItems: 'center', gap: 12, marginVertical: 12 },
  input: { borderWidth: 1, borderColor: '#ccc', borderRadius: 8, padding: 12, width: '100%', marginVertical: 8 },
  listItem: { padding: 12, borderBottomWidth: 1, borderBottomColor: '#eee', width: '100%' },
});
