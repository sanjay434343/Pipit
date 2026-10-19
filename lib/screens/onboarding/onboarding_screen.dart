// Pipit onboarding — minimal, always-white (single file Flutter port)
//
// pubspec.yaml:
//   dependencies:
//     flutter:
//       sdk: flutter
//     vibration: ^3.1.3     # precise waveform + amplitude haptics (Android)
//
// Haptics
//   Android   -> PRECISE: Vibration.vibrate(pattern, intensities)
//   iOS/other -> CORE: Flutter HapticFeedback
//   Any failure falls back to CORE.

import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:vibration/vibration.dart';

import '../../services/database_service.dart';
import '../../services/preferences_service.dart';

/* ───────────────────────── Palette (always white) ───────────────────────── */

class C {
  static const bg = Colors.white;
  static const ink = Color(0xFF0D110E);
  static const mute = Color(0xFF7A877E);
  static const line = Color(0xFFE8EEE9);
  static const tea = Color(0xFFEAF6E3);
  static const tea2 = Color(0xFFCFE9C0);
  static const acc = Color(0xFF1F9D57);
  static const deep = Color(0xFF0F6B3C);
  static const stroke = Color(0xFFC4D0C7);
}

const _ease = Cubic(.32, .72, 0, 1); // iOS sheet curve

/* ───────────────────────── Haptics map ─────────────────────────
   event -> precise waveform (Android) + core fallback (iOS / no vibrator)
   pattern: [wait, on, off, on, ...] ms   intensities: 0-255, same length
*/

enum Hx { tick, page, settle, next, tap, pill, pillOff, edge, success }

class Haptics {
  static bool _hasVib = false, _hasAmp = false;

  static const _pattern = <Hx, List<int>>{
    Hx.tick: [0, 3],
    Hx.page: [0, 8],
    Hx.settle: [0, 6],
    Hx.next: [0, 12],
    Hx.tap: [0, 6],
    Hx.pill: [0, 5],
    Hx.pillOff: [0, 3],
    Hx.edge: [0, 16, 40, 16],
    Hx.success: [0, 12, 50, 12, 50, 28],
  };
  static const _amp = <Hx, List<int>>{
    Hx.tick: [0, 30],
    Hx.page: [0, 70],
    Hx.settle: [0, 50],
    Hx.next: [0, 150],
    Hx.tap: [0, 80],
    Hx.pill: [0, 90],
    Hx.pillOff: [0, 50],
    Hx.edge: [0, 200, 0, 200],
    Hx.success: [0, 120, 0, 180, 0, 255],
  };

  static Future<void> init() async {
    try {
      _hasVib = (await Vibration.hasVibrator()) == true;
      _hasAmp = (await Vibration.hasAmplitudeControl()) == true;
    } catch (_) {}
  }

  static bool get _precise => !kIsWeb && defaultTargetPlatform == TargetPlatform.android && _hasVib;

  static void fire(Hx h) {
    if (_precise) {
      try {
        Vibration.vibrate(pattern: _pattern[h]!, intensities: _hasAmp ? _amp[h]! : const <int>[]);
        return;
      } catch (_) {}
    }
    unawaited(_core(h));
  }

  /// Indexing ramp: pulse strength grows with progress p (0-1).
  static void ramp(double p) {
    if (_precise) {
      try {
        Vibration.vibrate(
          pattern: [0, (3 + p * 9).round()],
          intensities: _hasAmp ? [0, (40 + p * 200).round()] : const <int>[],
        );
        return;
      } catch (_) {}
    }
    if (p < .4) {
      HapticFeedback.selectionClick();
    } else if (p < .8) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
  }

  static Future<void> _core(Hx h) async {
    try {
      switch (h) {
        case Hx.tick:
        case Hx.pillOff:
          await HapticFeedback.selectionClick();
          break;
        case Hx.page:
        case Hx.settle:
        case Hx.tap:
        case Hx.pill:
          await HapticFeedback.lightImpact();
          break;
        case Hx.next:
          await HapticFeedback.mediumImpact();
          break;
        case Hx.edge:
          await HapticFeedback.heavyImpact();
          await Future.delayed(const Duration(milliseconds: 40));
          await HapticFeedback.heavyImpact();
          break;
        case Hx.success:
          await HapticFeedback.mediumImpact();
          await Future.delayed(const Duration(milliseconds: 50));
          await HapticFeedback.mediumImpact();
          await Future.delayed(const Duration(milliseconds: 50));
          await HapticFeedback.heavyImpact();
          break;
      }
    } catch (_) {}
  }
}

/* ───────────────────────── App / Page ───────────────────────── */

enum Idx { idle, busy, done }

class _Q {
  final String q;
  final List<(String, String, String)> r;
  const _Q(this.q, this.r);
}

const _queries = [
  _Q('sunset at the beach', [
    ('IMG', 'IMG_0823.jpg', 'Photo · Today'),
    ('IMG', 'IMG_0791.jpg', 'Photo · Last week'),
    ('VID', 'Beach trip.mov', 'Video · August'),
  ]),
  _Q('invoice 4029', [
    ('PDF', 'Invoice_4029.pdf', 'Document · Yesterday'),
    ('MSG', 'Billing update', 'Message · Mon'),
    ('IMG', 'Receipt.jpg', 'Photo · Mar'),
  ]),
  _Q('gate code', [
    ('MSG', 'Message from building', 'Message · Yesterday'),
    ('PDF', 'Gate pass.pdf', 'Document · Jan'),
    ('CON', 'Security desk', 'Contact'),
  ]),
];

const _cats = ['Photos', 'Documents', 'Videos', 'Audio', 'Messages', 'Contacts', 'Apps'];

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> with TickerProviderStateMixin {
  // pager physics
  final ValueNotifier<double> posN = ValueNotifier(0), tN = ValueNotifier(0), ringP = ValueNotifier(0);
  late final Ticker _ticker;
  double _pos = 0, _vel = 0, _last = 0, _dragRaw = 0, _w = 360, _t = 0;
  int _target = 0, _lastR = 0, _lastSet = 0;
  bool _dragging = false, _prog = false, _lock = false, _ctaDown = false;

  // content state
  String typed = '';
  _Q? q;
  bool showRes = false, finShow = false;
  Idx st = Idx.idle;
  String title3 = 'Choose what\nto search.', sub3 = 'You can change this any time.';
  final List<bool> sel = List.filled(7, true);
  Timer? _idx;
  Timer? _autoNavigateTimer;
  bool _alive = true;
  bool _isNavigating = false;

  @override
  void initState() {
    super.initState();
    // Initialize category selections from Preferences
    sel[0] = PreferencesService.instance.isCategoryScanningEnabled('photos');
    sel[1] = PreferencesService.instance.isCategoryScanningEnabled('documents');
    sel[2] = PreferencesService.instance.isCategoryScanningEnabled('videos');
    sel[3] = PreferencesService.instance.isCategoryScanningEnabled('audio');
    sel[4] = PreferencesService.instance.isCategoryScanningEnabled('sms');
    sel[5] = PreferencesService.instance.isCategoryScanningEnabled('contacts');
    sel[6] = PreferencesService.instance.isCategoryScanningEnabled('apps');

    Haptics.init();
    _ticker = createTicker(_tick)..start();
    _demo();
  }

  @override
  void dispose() {
    _alive = false;
    _ticker.dispose();
    _idx?.cancel();
    _autoNavigateTimer?.cancel();
    posN.dispose();
    tN.dispose();
    ringP.dispose();
    super.dispose();
  }

  /* ---- spring pager ---- */
  void _tick(Duration e) {
    final now = e.inMicroseconds / 1000.0;
    final dt = min(.032, max(.001, (now - _last) / 1000));
    _last = now;
    _t = now / 1000;
    if (!_dragging) {
      const k = 190.0;
      final c = 2 * sqrt(k) * .9;
      _vel += ((_target - _pos) * k - _vel * c) * dt;
      _pos += _vel * dt;
      if (_vel.abs() < .001 && (_target - _pos).abs() < .0008) {
        _pos = _target.toDouble();
        _vel = 0;
        _prog = false;
        if (_lastSet != _target) {
          _lastSet = _target;
          Haptics.fire(Hx.settle);
        }
      }
    }
    posN.value = _pos;
    tN.value = _t;
    final r = _pos.round();
    if (r != _lastR) {
      _lastR = r;
      if (!_prog) Haptics.fire(Hx.page);
      setState(() {}); // CTA label, skip
    }
  }

  void go(int i, Hx kind) {
    if (_lock) return;
    _prog = true;
    _target = i.clamp(0, 2);
    Haptics.fire(kind);
  }

  double _band(double p) => p < 0 ? p * .45 : (p > 2 ? 2 + (p - 2) * .45 : p);
  double _unband(double p) => p < 0 ? p / .45 : (p > 2 ? 2 + (p - 2) / .45 : p);

  void _dragStart(DragStartDetails d) {
    if (_lock) return;
    _dragging = true;
    _prog = false;
    _dragRaw = _unband(_pos);
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    _dragRaw -= d.delta.dx / _w;
    _pos = _band(_dragRaw); // rubber band at the ends
  }

  void _dragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final v = -(d.primaryVelocity ?? 0) / _w;
    if (_pos < -.04 || _pos > 2.04) Haptics.fire(Hx.edge);
    _target = (_pos + v * .2).round().clamp(0, 2);
    _vel = v;
  }

  /* ---- page 1 demo ---- */
  Future<void> _demo() async {
    var i = 0;
    bool on() => _alive && (_pos - 0).abs() < .4;
    Future<void> w(int ms) => Future.delayed(Duration(milliseconds: ms));
    while (_alive) {
      if (!on()) {
        await w(250);
        continue;
      }
      final cur = _queries[i++ % _queries.length];
      for (final ch in cur.q.split('')) {
        if (!on()) break;
        setState(() => typed += ch);
        await w(55);
      }
      if (!_alive) return;
      setState(() {
        q = cur;
        showRes = true;
      });
      Haptics.fire(Hx.tick);
      await w(2300);
      if (!_alive) return;
      setState(() => showRes = false);
      await w(450);
      while (_alive && typed.isNotEmpty) {
        setState(() => typed = typed.substring(0, typed.length - 1));
        await w(18);
      }
      await w(300);
    }
  }

  /* ---- CTA ---- */
  String get _label {
    if (st == Idx.done) return 'Open Pipit';
    return ['Continue', 'Continue', 'Start indexing'][_pos.round().clamp(0, 2)];
  }

  int get _selCount => sel.where((e) => e).length;

  void _cta() {
    final r = _target;
    if (r < 2) return go(r + 1, Hx.next);
    if (st == Idx.done) {
      Haptics.fire(Hx.tap);
      setState(() => finShow = true);
      _autoNavigateTimer?.cancel();
      _autoNavigateTimer = Timer(const Duration(milliseconds: 2600), () {
        if (mounted && finShow) {
          _proceedToNext();
        }
      });
      return;
    }
    if (st != Idx.idle) return;
    if (_selCount == 0) {
      Haptics.fire(Hx.edge);
      return;
    }
    setState(() {
      st = Idx.busy;
      _lock = true;
    });
    Haptics.fire(Hx.tap);
    var p = 0.0, lastS = 0;
    final rnd = Random();
    _idx = Timer.periodic(const Duration(milliseconds: 70), (t) {
      p = min(1.0, p + .011 + rnd.nextDouble() * .018);
      ringP.value = p;
      final s = (p * 10).floor();
      if (s > lastS) {
        lastS = s;
        Haptics.ramp(p);
      }
      if (p >= 1) {
        t.cancel();
        setState(() {
          st = Idx.done;
          _lock = false;
          title3 = 'You’re all set.';
          sub3 = 'Pipit is indexing in the background. Search any time.';
        });
        ringP.value = 0;
        Haptics.fire(Hx.success);
      }
    });
  }

  Future<void> _proceedToNext() async {
    if (_isNavigating) return;
    _isNavigating = true;
    _autoNavigateTimer?.cancel();

    try {
      // 1. Persist chosen category scanning settings to Preferences & SQLite
      await PreferencesService.instance.setCategoryScanningEnabled('photos', sel[0]);
      await PreferencesService.instance.setCategoryScanningEnabled('documents', sel[1]);
      await PreferencesService.instance.setCategoryScanningEnabled('videos', sel[2]);
      await PreferencesService.instance.setCategoryScanningEnabled('audio', sel[3]);
      await PreferencesService.instance.setCategoryScanningEnabled('sms', sel[4]);
      await PreferencesService.instance.setCategoryScanningEnabled('contacts', sel[5]);
      await PreferencesService.instance.setCategoryScanningEnabled('apps', sel[6]);

      // 2. Mark onboarding as completed
      await PreferencesService.instance.setHasCompletedOnboarding(true);
      await DatabaseService.instance.setAppSetting('has_completed_onboarding', 'true');
    } catch (e) {
      debugPrint('[Onboarding] Error persisting preferences: $e');
    }

    if (!mounted) return;
    // 3. Router navigation
    context.go('/permissions');
  }

  void _replay() {
    _autoNavigateTimer?.cancel();
    _isNavigating = false;
    Haptics.fire(Hx.tap);
    setState(() {
      finShow = false;
      st = Idx.idle;
      title3 = 'Choose what\nto search.';
      sub3 = 'You can change this any time.';
      for (var i = 0; i < sel.length; i++) {
        sel[i] = true;
      }
    });
    _prog = true;
    _target = 0;
  }

  /* ───────────── UI ───────────── */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(children: [
        SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(children: [
                _header(),
                Expanded(child: _pager()),
                _footer(),
              ]),
            ),
          ),
        ),
        _final(),
      ]),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
        child: SizedBox(
          height: 40,
          child: Row(children: [
            AnimatedBuilder(
              animation: tN,
              builder: (context, child) {
                final ph = (tN.value % 3) / 3;
                return Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: C.acc,
                    boxShadow: [BoxShadow(color: C.acc.withValues(alpha: .45 * (1 - ph)), spreadRadius: 9 * ph)],
                  ),
                );
              },
            ),
            const SizedBox(width: 8),
            const Text('pipit', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -.5, color: C.ink)),
            const Spacer(),
            ValueListenableBuilder<double>(
              valueListenable: posN,
              builder: (context, p, child) => IgnorePointer(
                ignoring: p > .5,
                child: Opacity(
                  opacity: (1 - p * 1.1).clamp(0.0, 1.0).toDouble(),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => go(2, Hx.tap),
                    child: const Padding(
                      padding: EdgeInsets.fromLTRB(12, 8, 0, 8),
                      child: Text('Skip', style: TextStyle(fontSize: 15, color: C.mute)),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );

  Widget _pager() => LayoutBuilder(builder: (context, box) {
        _w = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _dragStart,
          onHorizontalDragUpdate: _dragUpdate,
          onHorizontalDragEnd: _dragEnd,
          child: ClipRect(
            child: ValueListenableBuilder<double>(
              valueListenable: posN,
              builder: (context, pos, child) => Stack(children: [
                for (var i = 0; i < 3; i++)
                  if ((i - pos).abs() <= 1.1) Positioned.fill(child: _page(i, pos, box.maxWidth)),
              ]),
            ),
          ),
        );
      });

  /// Layer with its own parallax speed [f], fade and blur — driven by the pager position.
  Widget _ly(int i, double f, double pos, double w, Widget child) {
    final d = i - pos, a = d.abs(), o = max(0.0, 1 - a * 1.25);
    Widget c = Opacity(opacity: o, child: child);
    if (a > .01) {
      final s = min(a * 9, 9.0);
      c = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: s), child: c);
    }
    return Transform.translate(offset: Offset(d * w * f, 0), child: c);
  }

  Widget _h1(String s) => Text(s, style: const TextStyle(fontSize: 34, height: 1.08, fontWeight: FontWeight.w600, letterSpacing: -1.4, color: C.ink));
  Widget _sub(String s) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(s, style: const TextStyle(fontSize: 17, height: 1.4, color: C.mute)),
      );

  Widget _page(int i, double pos, double w) {
    final children = switch (i) {
      0 => _page1(pos, w),
      1 => _page2(pos, w),
      _ => _page3(pos, w),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  /* ---- page 1 ---- */
  List<Widget> _page1(double pos, double w) => [
        _ly(0, .35, pos, w, _h1('Find anything\non your phone.')),
        _ly(0, .5, pos, w, _sub('Just describe it.')),
        _ly(
          0,
          .8,
          pos,
          w,
          Container(
            margin: const EdgeInsets.only(top: 30),
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(29),
              border: Border.all(color: C.line),
              boxShadow: [BoxShadow(color: C.ink.withValues(alpha: .14), blurRadius: 34, offset: const Offset(0, 14), spreadRadius: -22)],
            ),
            child: Row(children: [
              const Icon(Icons.search_rounded, size: 20, color: C.mute),
              const SizedBox(width: 12),
              Text(typed, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: C.ink)),
              AnimatedBuilder(
                animation: tN,
                builder: (context, child) => Opacity(
                  opacity: tN.value.floor().isEven ? 1 : 0,
                  child: Container(width: 2, height: 20, margin: const EdgeInsets.only(left: 2), color: C.acc),
                ),
              ),
            ]),
          ),
        ),
        _ly(
          0,
          .95,
          pos,
          w,
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Column(children: [
              if (q != null)
                for (var j = 0; j < q!.r.length; j++)
                  _ResRow(key: ValueKey('${q!.q}$j'), index: j, show: showRes, kind: q!.r[j].$1, name: q!.r[j].$2, meta: q!.r[j].$3),
            ]),
          ),
        ),
      ];

  /* ---- page 2 ---- */
  List<Widget> _page2(double pos, double w) => [
        _ly(1, .35, pos, w, _h1('Nothing leaves\nyour phone.')),
        _ly(1, .5, pos, w, _sub('Search runs on-device. No account, no internet.')),
        _ly(
          1,
          .8,
          pos,
          w,
          Padding(
            padding: const EdgeInsets.only(top: 34),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: AspectRatio(aspectRatio: 300 / 170, child: CustomPaint(painter: DiagramPainter(tN))),
            ),
          ),
        ),
        _ly(
          1,
          .95,
          pos,
          w,
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: const [
              Text('0', style: TextStyle(fontSize: 56, fontWeight: FontWeight.w300, letterSpacing: -2.8, height: 1, color: C.acc)),
              SizedBox(width: 10),
              Text('bytes uploaded, ever.', style: TextStyle(fontSize: 17, color: C.mute)),
            ]),
          ),
        ),
        _ly(
          1,
          1.05,
          pos,
          w,
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Wrap(spacing: 18, runSpacing: 8, children: [
              for (final t in const ['Offline', 'No account', 'No uploads'])
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_rounded, size: 15, color: C.acc),
                  const SizedBox(width: 6),
                  Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: C.ink)),
                ]),
            ]),
          ),
        ),
      ];

  /* ---- page 3 ---- */
  List<Widget> _page3(double pos, double w) => [
        _ly(2, .35, pos, w, _h1(title3)),
        _ly(2, .5, pos, w, _sub(sub3)),
        _ly(
          2,
          .85,
          pos,
          w,
          Padding(
            padding: const EdgeInsets.only(top: 30),
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              for (var k = 0; k < _cats.length; k++)
                _Pill(
                  label: _cats[k],
                  on: sel[k],
                  enabled: st == Idx.idle,
                  onTap: () {
                    setState(() => sel[k] = !sel[k]);
                    Haptics.fire(sel[k] ? Hx.pill : Hx.pillOff);
                  },
                ),
            ]),
          ),
        ),
        _ly(
          2,
          .95,
          pos,
          w,
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(st == Idx.done ? 'Ready' : '$_selCount of 7 selected', style: const TextStyle(fontSize: 14, color: C.mute)),
          ),
        ),
      ];

  /* ---- footer: hairline progress + morphing CTA ---- */
  Widget _footer() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 26),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ValueListenableBuilder<double>(
            valueListenable: posN,
            builder: (context, p, child) => Container(
              height: 2,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(2)),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: ((p + 1) / 3).clamp(0.0, 1.0).toDouble(),
                  child: Container(decoration: BoxDecoration(color: C.ink, borderRadius: BorderRadius.circular(2))),
                ),
              ),
            ),
          ),
          LayoutBuilder(builder: (context, box) {
            final busy = st == Idx.busy;
            final off = _pos.round() == 2 && st == Idx.idle && _selCount == 0;
            return Center(
              child: GestureDetector(
                onTapDown: (_) => setState(() => _ctaDown = true),
                onTapCancel: () => setState(() => _ctaDown = false),
                onTapUp: (_) => setState(() => _ctaDown = false),
                onTap: _cta,
                child: AnimatedScale(
                  scale: _ctaDown && !busy ? .97 : 1,
                  duration: const Duration(milliseconds: 450),
                  curve: _ease,
                  child: AnimatedOpacity(
                    opacity: off ? .35 : 1,
                    duration: const Duration(milliseconds: 400),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 800),
                      curve: _ease,
                      width: busy ? 56 : box.maxWidth,
                      height: 56,
                      decoration: BoxDecoration(color: st == Idx.done ? C.acc : C.ink, borderRadius: BorderRadius.circular(28)),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(alignment: Alignment.center, children: [
                        AnimatedOpacity(
                           opacity: busy ? 0 : 1,
                          duration: const Duration(milliseconds: 350),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 380),
                            switchInCurve: _ease,
                            transitionBuilder: (c, a) => FadeTransition(
                              opacity: a,
                              child: SlideTransition(position: Tween(begin: const Offset(0, .25), end: Offset.zero).animate(a), child: c),
                            ),
                            child: Text(
                              _label,
                              key: ValueKey(_label),
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500, letterSpacing: -.2, color: Colors.white),
                            ),
                          ),
                        ),
                        AnimatedOpacity(
                          opacity: busy ? 1 : 0,
                          duration: const Duration(milliseconds: 400),
                          child: ValueListenableBuilder<double>(
                            valueListenable: ringP,
                            builder: (context, p, child) => CustomPaint(size: const Size(56, 56), painter: _RingPainter(p)),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            );
          }),
        ]),
      );

  /* ---- final welcome overlay ---- */
  Widget _final() => IgnorePointer(
        ignoring: !finShow,
        child: AnimatedOpacity(
          opacity: finShow ? 1 : 0,
          duration: const Duration(milliseconds: 900),
          curve: _ease,
          child: Container(
            color: Colors.white,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(end: finShow ? 1 : 0),
                  duration: const Duration(milliseconds: 1300),
                  curve: _ease,
                  builder: (context, v, child) => CustomPaint(size: const Size(84, 84), painter: _CheckPainter(v)),
                ),
                const SizedBox(height: 26),
                const Text('Welcome to Pipit.', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w600, letterSpacing: -1.4, color: C.ink)),
                const SizedBox(height: 10),
                const Text('Find anything on your phone.', style: TextStyle(fontSize: 17, color: C.mute)),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: C.ink,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
                    ),
                    onPressed: _proceedToNext,
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Get Started', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: Colors.white)),
                        SizedBox(width: 8),
                        Icon(Icons.arrow_forward_rounded, size: 19, color: Colors.white),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _replay,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('Replay', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: C.mute)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

/* ───────────────────────── Widgets ───────────────────────── */

/// One search result row: fades up out of a blur, staggered by index.
class _ResRow extends StatelessWidget {
  final int index;
  final bool show;
  final String kind, name, meta;
  const _ResRow({super.key, required this.index, required this.show, required this.kind, required this.name, required this.meta});

  @override
  Widget build(BuildContext context) {
    final delay = index * 75, total = 800 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: show ? 1 : 0),
      duration: Duration(milliseconds: show ? total : 450),
      curve: show ? Interval(delay / total, 1, curve: _ease) : _ease,
      builder: (_, v, child) {
        Widget c = Transform.translate(
          offset: Offset(0, (1 - v) * 12),
          child: Transform.scale(scale: .985 + .015 * v, child: Opacity(opacity: v.clamp(0.0, 1.0).toDouble(), child: child)),
        );
        if (v < .98) c = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: (1 - v) * 6, sigmaY: (1 - v) * 6), child: c);
        return c;
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: index == 0 ? C.tea : Colors.transparent, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: index == 0 ? C.tea2 : C.line)),
            child: Text(kind, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: .4, color: C.deep)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, letterSpacing: -.15, color: C.ink)),
              const SizedBox(height: 2),
              Text(meta, style: const TextStyle(fontSize: 13, color: C.mute)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Toggle pill with a spring "pop" on tap.
class _Pill extends StatefulWidget {
  final String label;
  final bool on, enabled;
  final VoidCallback onTap;
  const _Pill({required this.label, required this.on, required this.enabled, required this.onTap});
  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 550));
  late final Animation<double> _s = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: .93).chain(CurveTween(curve: Curves.easeOut)), weight: 30),
    TweenSequenceItem(tween: Tween(begin: .93, end: 1.035).chain(CurveTween(curve: Curves.easeInOut)), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 1.035, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
  ]).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.on;
    return ScaleTransition(
      scale: _s,
      child: GestureDetector(
        onTap: widget.enabled
            ? () {
                _c.forward(from: 0);
                widget.onTap();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 450),
          curve: _ease,
          height: 48,
          padding: const EdgeInsets.fromLTRB(14, 0, 18, 0),
          decoration: BoxDecoration(
            color: on ? C.tea : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: on ? C.tea2 : C.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 450),
              curve: _ease,
              width: 20,
              height: 20,
              decoration: BoxDecoration(shape: BoxShape.circle, color: on ? C.acc : Colors.transparent, border: Border.all(color: on ? C.acc : C.line, width: 1.5)),
              child: AnimatedScale(
                scale: on ? 1 : 0,
                duration: const Duration(milliseconds: 500),
                curve: _ease,
                child: const Icon(Icons.check_rounded, size: 13, color: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 450),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: on ? C.deep : C.mute),
              child: Text(widget.label),
            ),
          ]),
        ),
      ),
    );
  }
}

/* ───────────────────────── Painters ───────────────────────── */

/// Privacy diagram: a packet tries to leave the phone and is blocked.
class DiagramPainter extends CustomPainter {
  final ValueNotifier<double> t;
  DiagramPainter(this.t) : super(repaint: t);

  double _pw(double x, List<List<double>> pts) {
    for (var i = 1; i < pts.length; i++) {
      if (x <= pts[i][0]) {
        final a = pts[i - 1], b = pts[i];
        final k = (x - a[0]) / (b[0] - a[0]);
        return a[1] + (b[1] - a[1]) * k;
      }
    }
    return pts.last[1];
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 300);
    final time = t.value;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = C.stroke;

    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(14, 8, 92, 154), const Radius.circular(22)), line);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(46, 16, 28, 6), const Radius.circular(3)), line);

    // pulsing rings
    for (final off in [0.0, 1.6]) {
      if (time < off) continue;
      final ph = ((time - off) % 3.2) / 3.2;
      canvas.drawCircle(
        const Offset(60, 85),
        8 * (1 + 2.4 * ph),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = C.acc.withValues(alpha: .6 * (1 - ph)),
      );
    }
    canvas.drawCircle(const Offset(60, 85), 8, Paint()..color = C.acc);

    // dashed link
    for (var x = 112.0; x < 186; x += 9) {
      canvas.drawLine(Offset(x, 85), Offset(min(x + 3, 186), 85), line);
    }

    // packet + blocked mark (3.6s loop)
    final ph = (time % 3.6) / 3.6;
    final op = _pw(ph, [[0, 0], [.1, 1], [.56, 1], [.72, 0], [1, 0]]);
    final dx = _pw(ph, [[0, 0], [.46, 36], [1, 36]]);
    final sc = _pw(ph, [[0, 1], [.46, 1], [.56, 1.5], [.72, 0], [1, 0]]);
    if (op > 0 && sc > 0) {
      canvas.drawCircle(Offset(124 + dx, 85), 4 * sc, Paint()..color = C.acc.withValues(alpha: op.clamp(0.0, 1.0).toDouble()));
    }
    final xs = _pw(ph, [[0, 1], [.44, 1], [.54, 1.35], [.66, 1], [1, 1]]);
    canvas.drawCircle(const Offset(150, 85), 11 * xs, Paint()..color = Colors.white);
    canvas.drawCircle(
      const Offset(150, 85),
      11 * xs,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = C.ink,
    );
    final cross = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = C.ink;
    canvas.drawLine(Offset(150 - 4 * xs, 85 - 4 * xs), Offset(150 + 4 * xs, 85 + 4 * xs), cross);
    canvas.drawLine(Offset(150 + 4 * xs, 85 - 4 * xs), Offset(150 - 4 * xs, 85 + 4 * xs), cross);

    // cloud
    final cloud = Path()
      ..moveTo(214, 112)
      ..lineTo(258, 112)
      ..arcToPoint(const Offset(260, 68.1), radius: const Radius.circular(22), clockwise: false)
      ..arcToPoint(const Offset(203, 62.1), radius: const Radius.circular(30), clockwise: false)
      ..arcToPoint(const Offset(214, 112), radius: const Radius.circular(26), clockwise: false)
      ..close();
    canvas.drawPath(cloud, line..color = C.stroke.withValues(alpha: .5));
  }

  @override
  bool shouldRepaint(DiagramPainter old) => false;
}

class _RingPainter extends CustomPainter {
  final double p;
  _RingPainter(this.p);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const r = 22.0;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white.withValues(alpha: .2),
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -pi / 2,
      2 * pi * p,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.p != p;
}

class _CheckPainter extends CustomPainter {
  final double p;
  _CheckPainter(this.p);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 84);
    canvas.drawCircle(
      const Offset(42, 42),
      40,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = C.tea2,
    );
    final path = Path()
      ..moveTo(27, 43)
      ..lineTo(37, 53)
      ..lineTo(57, 31);
    final m = path.computeMetrics().first;
    // check draws over the second half of the animation
    final k = ((p - .35) / .65).clamp(0.0, 1.0).toDouble();
    canvas.drawPath(
      m.extractPath(0, m.length * k),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = C.acc,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter o) => o.p != p;
}
