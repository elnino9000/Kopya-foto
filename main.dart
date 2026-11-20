import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

void main() => runApp(const KopyaFotoApp());

class KopyaFotoApp extends StatelessWidget {
  const KopyaFotoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kopya Foto',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF00796B),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF00796B),
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------- Veri

enum ScanMode { exact, similar }

enum Phase { idle, scanning, done }

class Photo {
  final AssetEntity asset;
  final int hash;
  int bytes = 0;
  String? md5sum;
  Photo(this.asset, this.hash);

  String get id => asset.id;
  int get pixels => asset.width * asset.height;
}

class Group {
  final List<Photo> items;
  final bool exact;
  final Set<String> selected = {};
  Group(this.items, this.exact);

  int get reclaim {
    var t = 0;
    for (final p in items) {
      if (selected.contains(p.id)) t += p.bytes;
    }
    return t;
  }

  /// En iyi fotoğraf kalsın, diğerleri silinmek üzere seçilsin.
  void autoSelect() {
    items.sort((a, b) {
      final c = b.pixels.compareTo(a.pixels);
      if (c != 0) return c;
      final d = b.bytes.compareTo(a.bytes);
      if (d != 0) return d;
      return a.asset.createDateTime.compareTo(b.asset.createDateTime);
    });
    selected
      ..clear()
      ..addAll(items.skip(1).map((p) => p.id));
  }
}

// ---------------------------------------------------------------- Yardımcılar

String fmtBytes(int b) {
  String s;
  if (b >= 1 << 30) {
    s = '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  } else if (b >= 1 << 20) {
    s = '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  } else if (b >= 1 << 10) {
    s = '${(b / 1024).round()} KB';
  } else {
    s = '$b B';
  }
  return s.replaceAll('.', ',');
}

String fmtDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

int _pop(int x) {
  x = x - ((x >>> 1) & 0x5555555555555555);
  x = (x & 0x3333333333333333) + ((x >>> 2) & 0x3333333333333333);
  x = (x + (x >>> 4)) & 0x0f0f0f0f0f0f0f0f;
  return (x * 0x0101010101010101) >>> 56;
}

/// Küçük bir resimden 64 bitlik "parmak izi" (dHash) çıkarır.
Future<int?> _hashOf(AssetEntity a) async {
  try {
    final data = await a.thumbnailDataWithSize(const ThumbnailSize(64, 64));
    if (data == null) return null;
    final codec =
        await ui.instantiateImageCodec(data, targetWidth: 9, targetHeight: 8);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final w = img.width;
    final h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    codec.dispose();
    if (bd == null || w < 2 || h < 1) return null;

    double lum(int gx, int gy) {
      final px = (((gx + 0.5) * w) / 9).floor().clamp(0, w - 1).toInt();
      final py = (((gy + 0.5) * h) / 8).floor().clamp(0, h - 1).toInt();
      final o = (py * w + px) * 4;
      return 0.299 * bd.getUint8(o) +
          0.587 * bd.getUint8(o + 1) +
          0.114 * bd.getUint8(o + 2);
    }

    var hash = 0;
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        hash = (hash << 1) | (lum(x, y) > lum(x + 1, y) ? 1 : 0);
      }
    }
    return hash;
  } catch (_) {
    return null;
  }
}

/// Ayrı bir iş parçacığında çalışır: birbirine yakın parmak izlerini gruplar.
List<dynamic> _clusterJob(Map<String, dynamic> args) {
  final hashes = (args['h'] as List).cast<int>();
  final asp = (args['a'] as List).cast<double>();
  final th = args['t'] as int;
  final n = hashes.length;
  final parent = List<int>.generate(n, (i) => i);

  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  for (var i = 0; i < n; i++) {
    final hi = hashes[i];
    final ai = asp[i];
    for (var j = i + 1; j < n; j++) {
      if ((asp[j] - ai).abs() > 0.06) continue;
      if (_pop(hi ^ hashes[j]) <= th) {
        final ri = find(i);
        final rj = find(j);
        if (ri != rj) parent[rj] = ri;
      }
    }
  }
  final m = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    m.putIfAbsent(find(i), () => <int>[]).add(i);
  }
  return m.values.where((g) => g.length > 1).toList();
}

final Map<String, Future<Uint8List?>> _thumbCache = {};

Future<Uint8List?> _thumb(AssetEntity a, int size) {
  return _thumbCache.putIfAbsent(
    '${a.id}_$size',
    () => a.thumbnailDataWithSize(ThumbnailSize(size, size)),
  );
}

class Thumb extends StatelessWidget {
  final AssetEntity asset;
  final int size;
  final BoxFit fit;
  const Thumb(
      {super.key, required this.asset, this.size = 320, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _thumb(asset, size),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) {
          return Container(color: Colors.black12);
        }
        return Image.memory(d,
            fit: fit,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true);
      },
    );
  }
}

// ---------------------------------------------------------------- Ana sayfa

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Phase _phase = Phase.idle;
  ScanMode _mode = ScanMode.exact;
  String? _error;
  String _status = '';
  int _done = 0;
  int _total = 0;
  int _scanned = 0;
  bool _cancel = false;
  bool _needSettings = false;
  List<Group> _groups = [];

  // ------------------------------------------------------------ Tarama

  Future<void> _scan() async {
    setState(() {
      _phase = Phase.scanning;
      _error = null;
      _needSettings = false;
      _cancel = false;
      _done = 0;
      _total = 0;
      _status = 'İzin kontrol ediliyor...';
    });

    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        setState(() {
          _phase = Phase.idle;
          _needSettings = true;
          _error = 'Fotoğraflara erişim izni verilmedi.';
        });
        return;
      }

      final paths = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );
      if (paths.isEmpty) {
        setState(() {
          _phase = Phase.idle;
          _error = 'Galeride fotoğraf bulunamadı.';
        });
        return;
      }

      final all = paths.first;
      final total = await all.assetCountAsync;
      setState(() {
        _total = total;
        _status = 'Fotoğraflar inceleniyor...';
      });

      final photos = <Photo>[];
      var done = 0;
      const page = 400;
      for (var start = 0; start < total; start += page) {
        if (_cancel) break;
        final end = math.min(start + page, total);
        final assets = await all.getAssetListRange(start: start, end: end);
        for (var i = 0; i < assets.length; i += 8) {
          if (_cancel) break;
          final chunk = assets.sublist(i, math.min(i + 8, assets.length));
          final res = await Future.wait(chunk.map(_hashOf));
          for (var k = 0; k < chunk.length; k++) {
            final h = res[k];
            if (h != null) photos.add(Photo(chunk[k], h));
          }
          done += chunk.length;
          if (mounted) setState(() => _done = done);
        }
      }

      if (_cancel) {
        if (mounted) setState(() => _phase = Phase.idle);
        return;
      }

      setState(() => _status = 'Benzerlikler karşılaştırılıyor...');
      final groups = await _buildGroups(photos);
      if (_cancel) {
        if (mounted) setState(() => _phase = Phase.idle);
        return;
      }

      for (final g in groups) {
        g.autoSelect();
      }
      groups.sort((a, b) => b.reclaim.compareTo(a.reclaim));

      if (!mounted) return;
      setState(() {
        _groups = groups;
        _scanned = total;
        _phase = Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.idle;
        _error = 'Tarama sırasında bir sorun oldu: $e';
      });
    }
  }

  Future<List<Group>> _buildGroups(List<Photo> photos) async {
    final exactMode = _mode == ScanMode.exact;
    final idxGroups = <List<int>>[];

    if (exactMode) {
      // Birebir aynı dosyaların parmak izi de aynıdır: sözlükle hızlıca grupla.
      final byHash = <int, List<int>>{};
      for (var i = 0; i < photos.length; i++) {
        byHash.putIfAbsent(photos[i].hash, () => <int>[]).add(i);
      }
      idxGroups.addAll(byHash.values.where((g) => g.length > 1));
    } else {
      // Düz renkli (neredeyse boş) resimler yanlış eşleşme yapar, onları atla.
      final cand = <int>[];
      for (var i = 0; i < photos.length; i++) {
        final bits = _pop(photos[i].hash);
        if (bits >= 6 && bits <= 58) cand.add(i);
      }
      final res = await compute(_clusterJob, <String, dynamic>{
        'h': cand.map((i) => photos[i].hash).toList(),
        'a': cand.map((i) {
          final a = photos[i].asset;
          return a.height == 0 ? 1.0 : a.width / a.height;
        }).toList(),
        't': 6,
      });
      for (final g in res) {
        idxGroups.add((g as List).map((k) => cand[k as int]).toList());
      }
    }

    final out = <Group>[];
    var n = 0;
    for (final ig in idxGroups) {
      if (_cancel) break;
      n++;
      if (mounted) {
        setState(() => _status = 'Kontrol ediliyor... ($n / ${idxGroups.length})');
      }
      final members = ig.map((i) => photos[i]).toList();
      for (final p in members) {
        try {
          final f = await p.asset.originFile;
          if (f != null) {
            p.bytes = await f.length();
            if (exactMode) {
              p.md5sum = (await md5.bind(f.openRead()).first).toString();
            }
          }
        } catch (_) {}
      }
      if (exactMode) {
        final byMd5 = <String, List<Photo>>{};
        for (final p in members) {
          final m = p.md5sum;
          if (m == null) continue;
          byMd5.putIfAbsent(m, () => <Photo>[]).add(p);
        }
        for (final l in byMd5.values) {
          if (l.length > 1) out.add(Group(l, true));
        }
      } else {
        out.add(Group(members, false));
      }
    }
    return out;
  }

  // ------------------------------------------------------------ Silme

  List<Photo> get _selectedPhotos {
    final l = <Photo>[];
    for (final g in _groups) {
      for (final p in g.items) {
        if (g.selected.contains(p.id)) l.add(p);
      }
    }
    return l;
  }

  Future<void> _deleteSelected() async {
    final sel = _selectedPhotos;
    if (sel.isEmpty) return;
    final size = sel.fold<int>(0, (s, p) => s + p.bytes);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${sel.length} fotoğraf silinsin mi?'),
        content: Text(
          'Yaklaşık ${fmtBytes(size)} yer açılacak.\n\n'
          'Her gruptan en iyi fotoğraf kalır. Android ayrıca onay isteyebilir; '
          'silinenler galerinin çöp kutusuna gidebilir, yer çöp boşaltılınca açılır.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final deleted =
          await PhotoManager.editor.deleteWithIds(sel.map((p) => p.id).toList());
      final ds = deleted.toSet();
      if (ds.isEmpty) {
        _snack('Silme işlemi yapılmadı.');
        return;
      }
      final freed =
          sel.where((p) => ds.contains(p.id)).fold<int>(0, (s, p) => s + p.bytes);
      setState(() {
        for (final g in _groups) {
          g.items.removeWhere((p) => ds.contains(p.id));
          g.selected.removeWhere(ds.contains);
        }
        _groups.removeWhere((g) => g.items.length < 2);
      });
      _snack('${ds.length} fotoğraf silindi, ${fmtBytes(freed)} yer açıldı.');
    } catch (e) {
      _snack('Silinemedi: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _toggle(Group g, Photo p) {
    setState(() {
      if (g.selected.contains(p.id)) {
        g.selected.remove(p.id);
      } else {
        if (g.selected.length + 1 >= g.items.length) {
          _snack('Her gruptan en az bir fotoğraf kalmalı.');
          return;
        }
        g.selected.add(p.id);
      }
    });
  }

  // ------------------------------------------------------------ Arayüz

  @override
  Widget build(BuildContext context) {
    final done = _phase == Phase.done;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kopya Foto'),
        actions: [
          if (done)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'auto') {
                  setState(() {
                    for (final g in _groups) {
                      g.autoSelect();
                    }
                  });
                } else if (v == 'clear') {
                  setState(() {
                    for (final g in _groups) {
                      g.selected.clear();
                    }
                  });
                } else if (v == 'rescan') {
                  _scan();
                }
              },
              itemBuilder: (c) => const [
                PopupMenuItem(
                    value: 'auto', child: Text('Otomatik seç (en iyisi kalsın)')),
                PopupMenuItem(value: 'clear', child: Text('Seçimi temizle')),
                PopupMenuItem(value: 'rescan', child: Text('Yeniden tara')),
              ],
            ),
        ],
      ),
      body: switch (_phase) {
        Phase.idle => _buildIdle(),
        Phase.scanning => _buildScanning(),
        Phase.done => _buildResults(),
      },
      bottomNavigationBar: done && _groups.isNotEmpty ? _buildBottomBar() : null,
    );
  }

  Widget _buildIdle() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 84, color: cs.primary),
            const SizedBox(height: 16),
            Text('Kopya fotoğrafları bul',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'Galerindeki aynı ve benzer fotoğrafları bulur, sana gösterir. '
              'Sen onaylamadan hiçbir şey silinmez.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SegmentedButton<ScanMode>(
              segments: const [
                ButtonSegment(
                    value: ScanMode.exact, label: Text('Birebir aynı')),
                ButtonSegment(value: ScanMode.similar, label: Text('Benzer')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _mode == ScanMode.exact
                  ? 'Dosyası bayt bayt aynı olanları bulur. Yanlış eşleşme olmaz.'
                  : 'Aynı kareyi tekrar çekilmiş, küçültülmüş veya hafif değişmiş '
                      'fotoğrafları da bulur. Silmeden önce göz atmak iyi olur.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.search),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                child: Text('Taramayı başlat'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.error)),
              if (_needSettings)
                TextButton(
                  onPressed: PhotoManager.openSetting,
                  child: const Text('Ayarları aç'),
                ),
            ],
            const SizedBox(height: 24),
            Text(
              'Fotoğrafların telefondan dışarı çıkmaz, her şey cihazında yapılır.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanning() {
    final value = _total > 0 && _status.startsWith('Fotoğraflar')
        ? (_done / _total).clamp(0.0, 1.0).toDouble()
        : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: value),
            const SizedBox(height: 20),
            Text(_status, textAlign: TextAlign.center),
            if (_total > 0 && value != null) ...[
              const SizedBox(height: 6),
              Text('$_done / $_total',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => setState(() => _cancel = true),
              child: const Text('İptal'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline,
                  size: 84, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('Kopya bulunamadı',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('$_scanned fotoğraf tarandı.'),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => setState(() => _phase = Phase.idle),
                child: const Text('Geri dön'),
              ),
            ],
          ),
        ),
      );
    }

    final extra = _groups.fold<int>(0, (s, g) => s + g.items.length - 1);
    final reclaimable = _groups.fold<int>(0, (s, g) => s + g.reclaim);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _groups.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return _buildSummary(extra, reclaimable);
        return _buildGroupCard(i, _groups[i - 1]);
      },
    );
  }

  Widget _buildSummary(int extra, int reclaimable) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$extra kopya fotoğraf bulundu',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('${_groups.length} grup · $_scanned fotoğraf tarandı\n'
                'Seçili olanlar silinirse ${fmtBytes(reclaimable)} yer açılır.'),
            const SizedBox(height: 8),
            Text(
              'Dokun: sil / kalsın arasında değiştir. Basılı tut: büyük göster.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupCard(int no, Group g) {
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Grup $no',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Chip(
                  label: Text(g.exact ? 'Birebir aynı' : 'Benzer'),
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                Text('${g.items.length} fotoğraf'),
              ],
            ),
            const SizedBox(height: 6),
            LayoutBuilder(builder: (context, c) {
              final w = ((c.maxWidth - 12) / 3).floorToDouble();
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final p in g.items) _tile(g, p, w)],
              );
            }),
            const SizedBox(height: 6),
            Text(
              g.selected.isEmpty
                  ? 'Hiçbiri silinmeyecek.'
                  : '${g.selected.length} tanesi silinecek (${fmtBytes(g.reclaim)}).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Group g, Photo p, double w) {
    final sel = g.selected.contains(p.id);
    return GestureDetector(
      onTap: () => _toggle(g, p),
      onLongPress: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ViewerPage(photo: p)),
      ),
      child: SizedBox(
        width: w,
        height: w,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Thumb(asset: p.asset),
              if (sel)
                Container(
                  color: const Color(0x99D32F2F),
                  alignment: Alignment.center,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline, color: Colors.white, size: 30),
                      Text('Silinecek',
                          style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              if (!sel)
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E7D32),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Kalacak',
                        style: TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  child: Text(
                    '${p.asset.width}×${p.asset.height}\n${fmtBytes(p.bytes)}',
                    style: const TextStyle(color: Colors.white, fontSize: 10.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final sel = _selectedPhotos;
    final size = sel.fold<int>(0, (s, p) => s + p.bytes);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: sel.isEmpty ? null : _deleteSelected,
          icon: const Icon(Icons.delete_outline),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(sel.isEmpty
                ? 'Silinecek fotoğraf seçilmedi'
                : 'Seçilenleri sil (${sel.length} · ${fmtBytes(size)})'),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Büyük görünüm

class ViewerPage extends StatelessWidget {
  final Photo photo;
  const ViewerPage({super.key, required this.photo});

  @override
  Widget build(BuildContext context) {
    final a = photo.asset;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${a.width}×${a.height} · ${fmtBytes(photo.bytes)}\n${fmtDate(a.createDateTime)}',
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Thumb(asset: a, size: 1600, fit: BoxFit.contain)),
      ),
    );
  }
}
