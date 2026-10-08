import 'dart:collection';

/// 带字节预算的 LRU 缓存。
///
/// 需求「五、素材显示」要求：**对常用图片实施有限缓存，不得无限缓存全部资源**。
/// 因此这里同时限制条目数与总字节数，并在淘汰时回调以便释放原生资源
/// （`ui.Image` 必须显式 dispose，否则会持续占用 GPU/CPU 内存）。
class LruCache<K, V> {
  LruCache({
    required this.maxEntries,
    required this.maxBytes,
    required this.sizeOf,
    this.onEvict,
  });

  /// 条目数上限。
  final int maxEntries;

  /// 字节上限。
  final int maxBytes;

  /// 计算单个值的字节占用。
  final int Function(K key, V value) sizeOf;

  /// 淘汰回调（用于 dispose）。
  final void Function(K key, V value)? onEvict;

  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();
  int _bytes = 0;

  int get length => _map.length;

  int get bytes => _bytes;

  bool containsKey(K key) => _map.containsKey(key);

  /// 取出并标记为最近使用。
  V? get(K key) {
    final V? value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value; // 重新插入到尾部 = 最近使用
    return value;
  }

  /// 只读窥视，不改变 LRU 顺序。
  V? peek(K key) => _map[key];

  void put(K key, V value) {
    final V? existing = _map.remove(key);
    if (existing != null) {
      _bytes -= sizeOf(key, existing);
      onEvict?.call(key, existing);
    }
    _map[key] = value;
    _bytes += sizeOf(key, value);
    _trim();
  }

  void remove(K key) {
    final V? existing = _map.remove(key);
    if (existing == null) return;
    _bytes -= sizeOf(key, existing);
    onEvict?.call(key, existing);
  }

  /// 清空并释放全部资源。
  void clear() {
    if (onEvict != null) {
      for (final MapEntry<K, V> e in _map.entries) {
        onEvict!.call(e.key, e.value);
      }
    }
    _map.clear();
    _bytes = 0;
  }

  void _trim() {
    while (_map.length > maxEntries || (_bytes > maxBytes && _map.length > 1)) {
      final K oldestKey = _map.keys.first;
      final V? oldest = _map.remove(oldestKey);
      if (oldest == null) break;
      _bytes -= sizeOf(oldestKey, oldest);
      onEvict?.call(oldestKey, oldest);
    }
  }

  Iterable<K> get keys => _map.keys;

  @override
  String toString() => 'LruCache(entries=$length, bytes=$_bytes, '
      'maxEntries=$maxEntries, maxBytes=$maxBytes)';
}
