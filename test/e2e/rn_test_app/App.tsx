import { initFlutterSkill, setNavigationRef, registerComponent, setDefaultScrollRef } from './FlutterSkill';
import React, { useState, useRef, useCallback, useEffect } from 'react';
import {
  View,
  Text,
  TextInput,
  FlatList,
  Switch,
  ScrollView,
  StyleSheet,
  TouchableOpacity,
  Modal,
  Alert,
  Image,
  StatusBar,
  Platform,
} from 'react-native';
import { NavigationContainer, useNavigation, NavigationContainerRef } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { createNativeStackNavigator } from '@react-navigation/native-stack';

// ─── Data ──────────────────────────────────────────────────────────────────

const FEED_POSTS = Array.from({ length: 30 }, (_, i) => ({
  id: String(i),
  author: ['Alice', 'Bob', 'Charlie', 'Diana', 'Eve', 'Frank', 'Grace', 'Hank'][i % 8],
  avatar: `https://i.pravatar.cc/48?img=${(i % 70) + 1}`,
  content: [
    'Just shipped a new feature! 🚀',
    'Beautiful sunset today 🌅',
    'Working on something exciting...',
    'Coffee and code ☕️',
    'Who else loves React Native?',
    'Hot take: tabs > spaces',
    'Weekend vibes 🎶',
    'Learning something new every day',
    'Check out this view! 🏔',
    'Late night coding session',
  ][i % 10],
  likes: Math.floor(Math.random() * 500),
  comments: Math.floor(Math.random() * 100),
  time: `${Math.floor(Math.random() * 23) + 1}h ago`,
  liked: false,
}));

const SEARCH_RESULTS = Array.from({ length: 50 }, (_, i) => ({
  id: String(i),
  title: `Result ${i + 1}: ${['React Native Tips', 'Mobile Dev', 'UI Design', 'TypeScript Tricks', 'App Performance', 'State Management', 'Navigation Patterns', 'Testing Guide'][i % 8]}`,
  category: ['Tech', 'Design', 'Tutorial', 'News', 'Opinion'][i % 5],
  snippet: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore.',
}));

const PROFILE_POSTS = Array.from({ length: 25 }, (_, i) => ({
  id: String(i),
  title: `My Post #${i + 1}`,
  likes: Math.floor(Math.random() * 200),
  date: `Feb ${(i % 28) + 1}, 2026`,
}));

// ─── Types ─────────────────────────────────────────────────────────────────

type RootStackParamList = {
  Main: undefined;
  PostDetail: { postId: string; author: string; content: string };
  SearchDetail: { resultId: string; title: string };
};

const Tab = createBottomTabNavigator();
const Stack = createNativeStackNavigator<RootStackParamList>();

// ─── Home Tab ──────────────────────────────────────────────────────────────

function HomeScreen() {
  const navigation = useNavigation<any>();
  const [posts, setPosts] = useState(FEED_POSTS);
  const [counter, setCounter] = useState(0);
  const [textInputValue, setTextInputValue] = useState('');
  const [checkboxValue, setCheckboxValue] = useState(false);
  const [submitted, setSubmitted] = useState('');

  const flatListRef = useRef<FlatList>(null);

  // Register components for flutter-skill SDK
  useEffect(() => {
    // Counter text
    registerComponent('counter', null, {
      type: 'text',
      getText: () => `Count: ${counterRef.current}`,
      accessibilityLabel: 'counter_text',
      interactive: true,
    });

    // Increment button
    registerComponent('increment-btn', null, {
      type: 'button',
      text: '+',
      accessibilityLabel: 'increment_btn',
      onPress: () => setCounter(c => c + 1),
      interactive: true,
    });

    // Decrement button
    registerComponent('decrement-btn', null, {
      type: 'button',
      text: '−',
      accessibilityLabel: 'decrement_btn',
      onPress: () => setCounter(c => c - 1),
      interactive: true,
    });

    // Text input
    registerComponent('text-input', null, {
      type: 'text_field',
      getText: () => textInputRef.current,
      accessibilityLabel: 'input_field',
      onChangeText: (text: string) => {
        textInputRef.current = text;
        setTextInputValue(text);
      },
      interactive: true,
    });

    // Submit button
    registerComponent('submit-btn', null, {
      type: 'button',
      text: 'Submit',
      accessibilityLabel: 'submit_btn',
      onPress: () => {
        setSubmitted(`Submitted: ${textInputRef.current}`);
      },
      interactive: true,
    });

    // Detail button - navigates to PostDetail
    registerComponent('detail-btn', null, {
      type: 'button',
      text: 'Detail',
      accessibilityLabel: 'detail_btn',
      onPress: () => {
        navigation.navigate('PostDetail', { postId: '0', author: 'Test', content: 'Test detail content' });
      },
      interactive: true,
    });

    // Checkbox (Switch)
    registerComponent('test-checkbox', null, {
      type: 'switch',
      getText: () => checkboxRef.current ? 'ON' : 'OFF',
      getValue: () => checkboxRef.current,
      accessibilityLabel: 'test_checkbox',
      onPress: () => {
        const newVal = !checkboxRef.current;
        checkboxRef.current = newVal;
        setCheckboxValue(newVal);
      },
      onValueChange: (val: boolean) => {
        checkboxRef.current = val;
        setCheckboxValue(val);
      },
      interactive: true,
    });

    return () => {
      ['counter', 'increment-btn', 'decrement-btn', 'text-input', 'submit-btn', 'detail-btn', 'test-checkbox'].forEach(
        k => registerComponent(k, null)
      );
    };
  }, [navigation]);

  // Mutable refs to track current values for closures
  const counterRef = useRef(counter);
  counterRef.current = counter;

  const textInputRef = useRef(textInputValue);
  textInputRef.current = textInputValue;

  const checkboxRef = useRef(checkboxValue);
  checkboxRef.current = checkboxValue;

  // Register FlatList as default scroll target
  useEffect(() => {
    if (flatListRef.current) {
      setDefaultScrollRef(flatListRef.current);
    }
  }, []);

  const toggleLike = useCallback((id: string) => {
    setPosts(prev =>
      prev.map(p =>
        p.id === id
          ? { ...p, liked: !p.liked, likes: p.liked ? p.likes - 1 : p.likes + 1 }
          : p,
      ),
    );
  }, []);

  const renderPost = useCallback(({ item }: { item: (typeof FEED_POSTS)[0] }) => (
    <TouchableOpacity
      style={styles.card}
      onPress={() => navigation.navigate('PostDetail', { postId: item.id, author: item.author, content: item.content })}
      accessibilityLabel={`list_item_${item.id}`}
    >
      <View style={styles.cardHeader}>
        <View style={styles.avatarPlaceholder}>
          <Text style={styles.avatarText}>{item.author[0]}</Text>
        </View>
        <View style={{ flex: 1 }}>
          <Text style={styles.authorName}>{item.author}</Text>
          <Text style={styles.timeText}>{item.time}</Text>
        </View>
      </View>
      <Text style={styles.postContent}>{item.content}</Text>
      <View style={styles.cardActions}>
        <TouchableOpacity
          onPress={() => toggleLike(item.id)}
          style={styles.actionBtn}
          accessibilityLabel={`like_btn_${item.id}`}
        >
          <Text>{item.liked ? '❤️' : '🤍'} {item.likes}</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.actionBtn} accessibilityLabel={`comment_btn_${item.id}`}>
          <Text>💬 {item.comments}</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.actionBtn}>
          <Text>🔗 Share</Text>
        </TouchableOpacity>
      </View>
    </TouchableOpacity>
  ), [navigation, toggleLike]);

  return (
    <View style={styles.screen}>
      {/* Counter section */}
      <View style={styles.counterSection}>
        <Text style={styles.counterText} accessibilityLabel="counter_text">Count: {counter}</Text>
        <View style={styles.row}>
          <TouchableOpacity
            style={styles.counterBtn}
            onPress={() => setCounter(c => c + 1)}
            accessibilityLabel="increment_btn"
          >
            <Text style={styles.counterBtnText}>+</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.counterBtn}
            onPress={() => setCounter(c => c - 1)}
            accessibilityLabel="decrement_btn"
          >
            <Text style={styles.counterBtnText}>−</Text>
          </TouchableOpacity>
        </View>

        {/* Test controls for bridge tests */}
        <TextInput
          style={[styles.input, { marginTop: 8, width: '100%' }]}
          placeholder="Enter text here..."
          value={textInputValue}
          onChangeText={(t) => { textInputRef.current = t; setTextInputValue(t); }}
          accessibilityLabel="input_field"
        />
        <View style={[styles.row, { marginTop: 8 }]}>
          <TouchableOpacity
            style={[styles.counterBtn, { width: 'auto', paddingHorizontal: 16, borderRadius: 10 }]}
            onPress={() => setSubmitted(`Submitted: ${textInputRef.current}`)}
            accessibilityLabel="submit_btn"
          >
            <Text style={styles.counterBtnText}>Submit</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.counterBtn, { width: 'auto', paddingHorizontal: 16, borderRadius: 10, backgroundColor: '#34C759' }]}
            onPress={() => navigation.navigate('PostDetail', { postId: '0', author: 'Test', content: 'Test detail content' })}
            accessibilityLabel="detail_btn"
          >
            <Text style={styles.counterBtnText}>Detail</Text>
          </TouchableOpacity>
        </View>
        <View style={[styles.row, { marginTop: 8, alignItems: 'center' }]}>
          <Text>Checkbox:</Text>
          <Switch
            value={checkboxValue}
            onValueChange={(val) => { checkboxRef.current = val; setCheckboxValue(val); }}
            accessibilityLabel="test_checkbox"
          />
          <Text>{checkboxValue ? 'ON' : 'OFF'}</Text>
        </View>
        {submitted ? <Text style={styles.resultText}>{submitted}</Text> : null}
      </View>

      <FlatList
        ref={flatListRef}
        data={posts}
        keyExtractor={item => item.id}
        renderItem={renderPost}
        contentContainerStyle={{ paddingBottom: 20 }}
        accessibilityLabel="item_list"
      />
    </View>
  );
}

// ─── Search Tab ────────────────────────────────────────────────────────────

function SearchScreen() {
  const navigation = useNavigation<any>();
  const [query, setQuery] = useState('');
  const [showTech, setShowTech] = useState(true);
  const [showDesign, setShowDesign] = useState(true);
  const [showTutorial, setShowTutorial] = useState(true);

  const filtered = SEARCH_RESULTS.filter(r => {
    if (!showTech && r.category === 'Tech') return false;
    if (!showDesign && r.category === 'Design') return false;
    if (!showTutorial && r.category === 'Tutorial') return false;
    if (query && !r.title.toLowerCase().includes(query.toLowerCase())) return false;
    return true;
  });

  return (
    <View style={styles.screen}>
      <TextInput
        style={styles.searchInput}
        placeholder="Search..."
        value={query}
        onChangeText={setQuery}
        accessibilityLabel="search_input"
      />
      <View style={styles.filterRow}>
        <View style={styles.filterItem}>
          <Text>Tech</Text>
          <Switch value={showTech} onValueChange={setShowTech} accessibilityLabel="filter_tech" />
        </View>
        <View style={styles.filterItem}>
          <Text>Design</Text>
          <Switch value={showDesign} onValueChange={setShowDesign} accessibilityLabel="filter_design" />
        </View>
        <View style={styles.filterItem}>
          <Text>Tutorial</Text>
          <Switch value={showTutorial} onValueChange={setShowTutorial} accessibilityLabel="filter_tutorial" />
        </View>
      </View>
      <FlatList
        data={filtered}
        keyExtractor={item => item.id}
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.searchItem}
            onPress={() => navigation.navigate('SearchDetail', { resultId: item.id, title: item.title })}
            accessibilityLabel={`search_result_${item.id}`}
          >
            <View style={styles.categoryBadge}>
              <Text style={styles.categoryText}>{item.category}</Text>
            </View>
            <Text style={styles.searchTitle}>{item.title}</Text>
            <Text style={styles.searchSnippet} numberOfLines={2}>{item.snippet}</Text>
          </TouchableOpacity>
        )}
        contentContainerStyle={{ paddingBottom: 20 }}
        accessibilityLabel="search_list"
      />
    </View>
  );
}

// ─── Create Tab ────────────────────────────────────────────────────────────

function CreateScreen() {
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [category, setCategory] = useState('General');
  const [isPublic, setIsPublic] = useState(true);
  const [enableComments, setEnableComments] = useState(true);
  const [submitted, setSubmitted] = useState('');

  const categories = ['General', 'Tech', 'Design', 'Tutorial', 'News'];

  const handleSubmit = () => {
    if (!title.trim()) {
      Alert.alert('Error', 'Title is required');
      return;
    }
    setSubmitted(`Submitted: ${title} [${category}]`);
    setTitle('');
    setBody('');
  };

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.formContainer}>
      <Text style={styles.sectionTitle}>Create New Post</Text>

      <Text style={styles.label}>Title</Text>
      <TextInput
        style={styles.input}
        placeholder="Enter post title"
        value={title}
        onChangeText={setTitle}
        accessibilityLabel="input_field"
      />

      <Text style={styles.label}>Content</Text>
      <TextInput
        style={[styles.input, styles.multilineInput]}
        placeholder="Write your post content..."
        value={body}
        onChangeText={setBody}
        multiline
        numberOfLines={6}
        textAlignVertical="top"
        accessibilityLabel="content_input"
      />

      <Text style={styles.label}>Category</Text>
      <View style={styles.pickerRow}>
        {categories.map(cat => (
          <TouchableOpacity
            key={cat}
            style={[styles.pickerOption, category === cat && styles.pickerOptionSelected]}
            onPress={() => setCategory(cat)}
            accessibilityLabel={`category_${cat.toLowerCase()}`}
          >
            <Text style={category === cat ? styles.pickerOptionTextSelected : styles.pickerOptionText}>{cat}</Text>
          </TouchableOpacity>
        ))}
      </View>

      <View style={styles.switchRow}>
        <Text>Public Post</Text>
        <Switch value={isPublic} onValueChange={setIsPublic} accessibilityLabel="test_switch" />
        <Text accessibilityLabel="switch_status">{isPublic ? 'ON' : 'OFF'}</Text>
      </View>

      <View style={styles.switchRow}>
        <Text>Enable Comments</Text>
        <Switch value={enableComments} onValueChange={setEnableComments} accessibilityLabel="comments_switch" />
      </View>

      <TouchableOpacity style={styles.submitButton} onPress={handleSubmit} accessibilityLabel="submit_btn">
        <Text style={styles.submitButtonText}>Publish Post</Text>
      </TouchableOpacity>

      {submitted ? (
        <Text style={styles.resultText} accessibilityLabel="result_text">{submitted}</Text>
      ) : null}
    </ScrollView>
  );
}

// ─── Profile Tab ───────────────────────────────────────────────────────────

function ProfileScreen() {
  const [settingsVisible, setSettingsVisible] = useState(false);
  const [darkMode, setDarkMode] = useState(false);
  const [notifications, setNotifications] = useState(true);

  return (
    <View style={styles.screen}>
      <View style={styles.profileHeader}>
        <View style={styles.profileAvatar}>
          <Text style={styles.profileAvatarText}>JD</Text>
        </View>
        <Text style={styles.profileName} accessibilityLabel="profile_name">John Doe</Text>
        <Text style={styles.profileBio}>React Native Developer • Coffee Enthusiast</Text>
      </View>

      <View style={styles.statsRow}>
        <View style={styles.statItem}>
          <Text style={styles.statNumber}>128</Text>
          <Text style={styles.statLabel}>Posts</Text>
        </View>
        <View style={styles.statItem}>
          <Text style={styles.statNumber}>4.2K</Text>
          <Text style={styles.statLabel}>Followers</Text>
        </View>
        <View style={styles.statItem}>
          <Text style={styles.statNumber}>892</Text>
          <Text style={styles.statLabel}>Following</Text>
        </View>
      </View>

      <TouchableOpacity
        style={styles.settingsBtn}
        onPress={() => setSettingsVisible(true)}
        accessibilityLabel="settings_btn"
      >
        <Text style={styles.settingsBtnText}>⚙️ Settings</Text>
      </TouchableOpacity>

      <FlatList
        data={PROFILE_POSTS}
        keyExtractor={item => item.id}
        renderItem={({ item }) => (
          <View style={styles.profilePost} accessibilityLabel={`profile_post_${item.id}`}>
            <Text style={styles.profilePostTitle}>{item.title}</Text>
            <Text style={styles.profilePostMeta}>❤️ {item.likes} · {item.date}</Text>
          </View>
        )}
        contentContainerStyle={{ paddingBottom: 20 }}
        accessibilityLabel="profile_posts_list"
      />

      <Modal visible={settingsVisible} animationType="slide" transparent accessibilityLabel="settings_modal">
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>Settings</Text>
            <View style={styles.settingItem}>
              <Text>Dark Mode</Text>
              <Switch value={darkMode} onValueChange={setDarkMode} accessibilityLabel="dark_mode_switch" />
            </View>
            <View style={styles.settingItem}>
              <Text>Notifications</Text>
              <Switch value={notifications} onValueChange={setNotifications} accessibilityLabel="notifications_switch" />
            </View>
            <View style={styles.settingItem}>
              <Text>App Version</Text>
              <Text style={styles.settingValue}>1.0.0</Text>
            </View>
            <TouchableOpacity
              style={styles.modalCloseBtn}
              onPress={() => setSettingsVisible(false)}
              accessibilityLabel="close_settings_btn"
            >
              <Text style={styles.modalCloseBtnText}>Close</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>
    </View>
  );
}

// ─── Detail Screens ────────────────────────────────────────────────────────

function PostDetailScreen({ route }: any) {
  const navigation = useNavigation();
  const { postId, author, content } = route.params;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.detailContainer}>
      <Text style={styles.detailTitle} accessibilityLabel="detail_title">Post by {author}</Text>
      <Text style={styles.detailContent}>{content}</Text>
      <Text style={styles.detailMeta}>Post ID: {postId}</Text>

      <View style={{ marginTop: 20 }}>
        <Text style={styles.sectionTitle}>Comments</Text>
        {Array.from({ length: 10 }, (_, i) => (
          <View key={i} style={styles.commentItem}>
            <Text style={styles.commentAuthor}>User{i + 1}</Text>
            <Text>Great post! This is comment #{i + 1}</Text>
          </View>
        ))}
      </View>

      <TouchableOpacity
        style={styles.backBtn}
        onPress={() => navigation.goBack()}
        accessibilityLabel="back_btn"
      >
        <Text style={styles.backBtnText}>← Go Back</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

function SearchDetailScreen({ route }: any) {
  const navigation = useNavigation();
  const { resultId, title } = route.params;

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.detailContainer}>
      <Text style={styles.detailTitle} accessibilityLabel="detail_title">{title}</Text>
      <Text style={styles.detailContent}>
        This is the full content for search result #{resultId}. In a real app, this would contain
        the complete article, tutorial, or discussion thread. Lorem ipsum dolor sit amet,
        consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
      </Text>

      <TouchableOpacity
        style={styles.backBtn}
        onPress={() => navigation.goBack()}
        accessibilityLabel="detail_btn"
      >
        <Text style={styles.backBtnText}>← Go Back</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

// ─── Tab Icon Helper ───────────────────────────────────────────────────────

function TabIcon({ label, focused }: { label: string; focused: boolean }) {
  const icons: Record<string, string> = { Home: '🏠', Search: '🔍', Create: '✏️', Profile: '👤' };
  return (
    <Text style={{ fontSize: 22, opacity: focused ? 1 : 0.5 }}>{icons[label] || '•'}</Text>
  );
}

// ─── Main Tabs ─────────────────────────────────────────────────────────────

function MainTabs() {
  return (
    <Tab.Navigator
      screenOptions={({ route }) => ({
        tabBarIcon: ({ focused }) => <TabIcon label={route.name} focused={focused} />,
        tabBarActiveTintColor: '#007AFF',
        tabBarInactiveTintColor: '#999',
        headerShown: true,
      })}
    >
      <Tab.Screen name="Home" component={HomeScreen} />
      <Tab.Screen name="Search" component={SearchScreen} />
      <Tab.Screen name="Create" component={CreateScreen} />
      <Tab.Screen name="Profile" component={ProfileScreen} />
    </Tab.Navigator>
  );
}

// ─── Navigation Ref (for SDK) ──────────────────────────────────────────────

export const navigationRef = React.createRef<NavigationContainerRef<any>>();

// ─── App ───────────────────────────────────────────────────────────────────

// Initialize flutter-skill bridge in dev mode
if (__DEV__) {
  initFlutterSkill({ appName: 'RNTestApp' });
}

export default function App() {
  useEffect(() => {
    if (__DEV__) {
      setNavigationRef(navigationRef);
    }
  }, []);

  return (
    <>
      <StatusBar barStyle="dark-content" />
      <NavigationContainer ref={navigationRef}>
        <Stack.Navigator>
          <Stack.Screen name="Main" component={MainTabs} options={{ headerShown: false }} />
          <Stack.Screen name="PostDetail" component={PostDetailScreen} options={{ title: 'Post' }} />
          <Stack.Screen name="SearchDetail" component={SearchDetailScreen} options={{ title: 'Detail' }} />
        </Stack.Navigator>
      </NavigationContainer>
    </>
  );
}

// ─── Styles ────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#f5f5f5' },
  counterSection: { padding: 16, backgroundColor: '#fff', borderBottomWidth: 1, borderBottomColor: '#eee', alignItems: 'center' },
  counterText: { fontSize: 20, fontWeight: '600', marginBottom: 8 },
  row: { flexDirection: 'row', gap: 12 },
  counterBtn: { backgroundColor: '#007AFF', width: 44, height: 44, borderRadius: 22, alignItems: 'center', justifyContent: 'center' },
  counterBtnText: { color: '#fff', fontSize: 22, fontWeight: 'bold' },
  card: { backgroundColor: '#fff', marginHorizontal: 12, marginTop: 12, borderRadius: 12, padding: 16, shadowColor: '#000', shadowOpacity: 0.05, shadowRadius: 4, shadowOffset: { width: 0, height: 2 }, elevation: 2 },
  cardHeader: { flexDirection: 'row', alignItems: 'center', marginBottom: 10 },
  avatarPlaceholder: { width: 40, height: 40, borderRadius: 20, backgroundColor: '#007AFF', alignItems: 'center', justifyContent: 'center', marginRight: 10 },
  avatarText: { color: '#fff', fontWeight: 'bold', fontSize: 16 },
  authorName: { fontWeight: '600', fontSize: 15 },
  timeText: { color: '#999', fontSize: 12, marginTop: 2 },
  postContent: { fontSize: 15, lineHeight: 22, marginBottom: 12 },
  cardActions: { flexDirection: 'row', gap: 16, paddingTop: 8, borderTopWidth: 1, borderTopColor: '#f0f0f0' },
  actionBtn: { paddingVertical: 4 },
  searchInput: { margin: 12, padding: 12, backgroundColor: '#fff', borderRadius: 10, fontSize: 16, borderWidth: 1, borderColor: '#ddd' },
  filterRow: { flexDirection: 'row', justifyContent: 'space-around', paddingHorizontal: 12, paddingBottom: 8 },
  filterItem: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  searchItem: { backgroundColor: '#fff', marginHorizontal: 12, marginTop: 8, borderRadius: 10, padding: 14 },
  categoryBadge: { backgroundColor: '#e8f0fe', paddingHorizontal: 8, paddingVertical: 2, borderRadius: 4, alignSelf: 'flex-start', marginBottom: 6 },
  categoryText: { color: '#007AFF', fontSize: 12, fontWeight: '600' },
  searchTitle: { fontSize: 15, fontWeight: '600', marginBottom: 4 },
  searchSnippet: { fontSize: 13, color: '#666', lineHeight: 18 },
  formContainer: { padding: 16 },
  sectionTitle: { fontSize: 20, fontWeight: 'bold', marginBottom: 16 },
  label: { fontSize: 14, fontWeight: '600', marginBottom: 6, color: '#333' },
  input: { backgroundColor: '#fff', borderWidth: 1, borderColor: '#ddd', borderRadius: 10, padding: 12, fontSize: 16, marginBottom: 16 },
  multilineInput: { minHeight: 120, textAlignVertical: 'top' },
  pickerRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 16 },
  pickerOption: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: 20, backgroundColor: '#eee' },
  pickerOptionSelected: { backgroundColor: '#007AFF' },
  pickerOptionText: { color: '#333' },
  pickerOptionTextSelected: { color: '#fff', fontWeight: '600' },
  switchRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingVertical: 10 },
  submitButton: { backgroundColor: '#007AFF', padding: 16, borderRadius: 12, alignItems: 'center', marginTop: 16 },
  submitButtonText: { color: '#fff', fontSize: 17, fontWeight: '600' },
  resultText: { fontSize: 15, marginTop: 12, color: '#007AFF', textAlign: 'center' },
  profileHeader: { alignItems: 'center', paddingVertical: 24, backgroundColor: '#fff' },
  profileAvatar: { width: 80, height: 80, borderRadius: 40, backgroundColor: '#007AFF', alignItems: 'center', justifyContent: 'center', marginBottom: 12 },
  profileAvatarText: { color: '#fff', fontSize: 28, fontWeight: 'bold' },
  profileName: { fontSize: 22, fontWeight: 'bold' },
  profileBio: { fontSize: 14, color: '#666', marginTop: 4 },
  statsRow: { flexDirection: 'row', justifyContent: 'space-around', paddingVertical: 16, backgroundColor: '#fff', borderTopWidth: 1, borderBottomWidth: 1, borderColor: '#eee' },
  statItem: { alignItems: 'center' },
  statNumber: { fontSize: 20, fontWeight: 'bold' },
  statLabel: { fontSize: 12, color: '#999', marginTop: 2 },
  settingsBtn: { margin: 12, padding: 12, backgroundColor: '#fff', borderRadius: 10, alignItems: 'center' },
  settingsBtnText: { fontSize: 16 },
  profilePost: { backgroundColor: '#fff', marginHorizontal: 12, marginTop: 8, borderRadius: 10, padding: 14 },
  profilePostTitle: { fontSize: 15, fontWeight: '600' },
  profilePostMeta: { fontSize: 13, color: '#999', marginTop: 4 },
  detailContainer: { padding: 20 },
  detailTitle: { fontSize: 24, fontWeight: 'bold', marginBottom: 16 },
  detailContent: { fontSize: 16, lineHeight: 24, color: '#333', marginBottom: 16 },
  detailMeta: { fontSize: 13, color: '#999', marginBottom: 20 },
  commentItem: { paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: '#eee' },
  commentAuthor: { fontWeight: '600', marginBottom: 4 },
  backBtn: { marginTop: 20, padding: 14, backgroundColor: '#007AFF', borderRadius: 10, alignItems: 'center' },
  backBtnText: { color: '#fff', fontSize: 16, fontWeight: '600' },
  modalOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end' },
  modalContent: { backgroundColor: '#fff', borderTopLeftRadius: 20, borderTopRightRadius: 20, padding: 24 },
  modalTitle: { fontSize: 22, fontWeight: 'bold', marginBottom: 20 },
  settingItem: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingVertical: 14, borderBottomWidth: 1, borderBottomColor: '#eee' },
  settingValue: { color: '#999' },
  modalCloseBtn: { marginTop: 20, padding: 14, backgroundColor: '#007AFF', borderRadius: 10, alignItems: 'center' },
  modalCloseBtnText: { color: '#fff', fontSize: 16, fontWeight: '600' },
});
