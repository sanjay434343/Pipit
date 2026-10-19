import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../services/database_service.dart';
import '../../services/preferences_service.dart';
import '../home/home_screen.dart';

/// Fast, fluid startup splash screen that seamlessly reveals the underlying
/// Home screen with a smooth continuous white wave and continuous high-to-low vibration.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoController;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;

  late final AnimationController _waveController;
  late final Animation<double> _waveAnimation;
  late final Animation<double> _logoExitFade;
  late final Animation<double> _logoExitSlide;

  Timer? _waveStartTimer;
  Timer? _hapticTimer;
  bool _hasNavigated = false;
  bool _hasVisitedAll = false;

  @override
  void initState() {
    super.initState();

    // Check SharedPreferences / DB if user has previously completed all steps
    _hasVisitedAll = PreferencesService.instance.hasVisitedAll;
    DatabaseService.instance.getAppSetting('has_visited_all').then((val) {
      if (mounted) {
        final visited = (val == 'true') || _hasVisitedAll;
        if (visited != _hasVisitedAll) {
          setState(() {
            _hasVisitedAll = visited;
          });
          PreferencesService.instance.setHasVisitedAll(visited);
        }
      }
    });

    // 1. Snappy logo intro (360ms easeOutCubic)
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );

    _scaleAnimation = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _logoController, curve: Curves.easeOut));

    // 2. Fast & smooth upward wave sweep (600ms fluid curve)
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _waveAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _waveController, curve: Curves.fastOutSlowIn),
    );

    // Logo floats upward and dissolves softly during wave sweep
    _logoExitSlide = Tween<double>(
      begin: 0.0,
      end: -40.0,
    ).animate(CurvedAnimation(parent: _waveController, curve: Curves.easeOut));

    _logoExitFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _waveController,
        curve: const Interval(0.15, 0.60, curve: Curves.easeIn),
      ),
    );

    _waveController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _navigateToNext();
      }
    });

    _logoController.forward();

    // Splash runs for 4 seconds in total:
    // Logo displays until 3400ms, then fast 600ms upward wave sweeps to complete at exactly 4000ms
    _waveStartTimer = Timer(const Duration(milliseconds: 3400), () {
      if (mounted && !_hasNavigated) {
        _waveController.forward();
        _startContinuousHaptics();
      }
    });
  }

  /// Delivers continuous, high-speed silky-smooth micro-vibrations transitioning seamlessly
  /// from rapid high-frequency pulses to gentle low-frequency pulses (fast, continuous).
  void _startContinuousHaptics() {
    _hapticTimer?.cancel();
    if (!mounted || _hasNavigated) return;

    double intervalMs = 14.0;
    const double intervalIncrement = 1.4;
    const double maxInterval = 40.0;

    void triggerTick() {
      if (!mounted || _hasNavigated || !_waveController.isAnimating) return;
      HapticFeedback.selectionClick();

      intervalMs += intervalIncrement;
      if (intervalMs <= maxInterval) {
        _hapticTimer = Timer(
          Duration(milliseconds: intervalMs.round()),
          triggerTick,
        );
      }
    }

    triggerTick();
  }

  Future<void> _navigateToNext() async {
    if (_hasNavigated || !mounted) return;
    _hasNavigated = true;
    _waveStartTimer?.cancel();
    _hapticTimer?.cancel();

    final hasVisitedAll = PreferencesService.instance.hasVisitedAll;
    if (hasVisitedAll) {
      if (mounted) context.go('/home');
      return;
    }

    final dbVisited = await DatabaseService.instance.getAppSetting('has_visited_all');
    if (!mounted) return;
    if (dbVisited == 'true') {
      await PreferencesService.instance.setHasVisitedAll(true);
      if (mounted) context.go('/home');
      return;
    }

    final hasCompletedOnboarding = PreferencesService.instance.hasCompletedOnboarding;
    final dbOnboard = await DatabaseService.instance.getAppSetting('has_completed_onboarding');
    if (!mounted) return;
    if (!hasCompletedOnboarding && dbOnboard != 'true') {
      context.go('/onboarding');
      return;
    } else if (dbOnboard == 'true' && !hasCompletedOnboarding) {
      await PreferencesService.instance.setHasCompletedOnboarding(true);
      if (!mounted) return;
    }

    final hasCompletedPermissions = PreferencesService.instance.hasCompletedPermissions;
    final dbPerm = await DatabaseService.instance.getAppSetting('has_completed_permissions');
    if (!mounted) return;
    if (!hasCompletedPermissions && dbPerm != 'true') {
      context.go('/permissions');
    } else {
      await PreferencesService.instance.setHasVisitedAll(true);
      if (mounted) context.go('/home');
    }
  }

  @override
  void dispose() {
    _waveStartTimer?.cancel();
    _hapticTimer?.cancel();
    _logoController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. BEHIND LAYER: The live Home Screen only if user has previously completed setup
          if (_hasVisitedAll)
            const HomeScreen(isSplashPreview: true)
          else
            const SizedBox.shrink(),

          // 2. FOREGROUND LAYER: The Fast, Smooth Splash Overlay with upward White Wave Reveal
          GestureDetector(
            onTap: _navigateToNext,
            behavior: HitTestBehavior.opaque,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double w = constraints.maxWidth;
                final double h = constraints.maxHeight;

                return AnimatedBuilder(
                  animation: Listenable.merge([
                    _logoController,
                    _waveController,
                  ]),
                  builder: (context, child) {
                    final double progress = _waveAnimation.value;

                    // Continuous wave crest elevation from h+30 to -140
                    final double crestY = (h + 30.0) - progress * (h + 170.0);
                    final double arch =
                        28.0 * math.sin(progress.clamp(0.0, 1.0) * math.pi);

                    final bool isOverStatusBar = crestY > 60;

                    return AnnotatedRegion<SystemUiOverlayStyle>(
                      value: SystemUiOverlayStyle(
                        statusBarColor: Colors.transparent,
                        statusBarIconBrightness: isOverStatusBar
                            ? Brightness.light
                            : Brightness.dark,
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Clipped Splash Background (Teal Gradient + Center Logo)
                          // Smoothly opens upward, revealing the Home screen from the bottom up!
                          ClipPath(
                            clipper: _SplashRevealClipper(
                              crestY: crestY,
                              arch: arch,
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Container(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xFF15786C),
                                        Color(0xFF15786C),
                                        Color(0xFF2E8E82),
                                        Color(0xFF67B2A8),
                                        Color(0xFFD6EAE6),
                                      ],
                                      stops: [0.0, 0.22, 0.52, 0.78, 1.0],
                                    ),
                                  ),
                                ),
                                Center(
                                  child: Transform.translate(
                                    offset: Offset(0, _logoExitSlide.value),
                                    child: Opacity(
                                      opacity:
                                          (_fadeAnimation.value *
                                                  _logoExitFade.value)
                                              .clamp(0.0, 1.0),
                                      child: ScaleTransition(
                                        scale: _scaleAnimation,
                                        child: SizedBox(
                                          width: 190,
                                          height: 190,
                                          child: Image.asset(
                                            'assets/iamges/logo.png',
                                            fit: BoxFit.contain,
                                            filterQuality: FilterQuality.high,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Fluid Glowing White Wave Crest along crestY
                          if (progress > 0.0 &&
                              crestY > -140 &&
                              crestY < h + 25)
                            CustomPaint(
                              size: Size(w, h),
                              painter: _WaveCrestPainter(
                                crestY: crestY,
                                arch: arch,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Clips away everything below the upward-sweeping curved wave line,
/// revealing the underlying content from the bottom up.
class _SplashRevealClipper extends CustomClipper<Path> {
  final double crestY;
  final double arch;

  _SplashRevealClipper({required this.crestY, required this.arch});

  @override
  Path getClip(Size size) {
    final double w = size.width;
    final double h = size.height;

    // Retain full overlay before wave starts
    if (crestY >= h + 20) {
      return Path()..addRect(Rect.fromLTWH(0, 0, w, h));
    }
    // Completely clipped out once wave clears top
    if (crestY <= -130) {
      return Path();
    }

    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(w, 0);
    path.lineTo(w, crestY);
    path.quadraticBezierTo(w * 0.5, crestY - arch, 0, crestY);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _SplashRevealClipper oldClipper) {
    return oldClipper.crestY != crestY || oldClipper.arch != arch;
  }
}

/// Paints the fluid, luminous white wave crest that sweeps upward.
class _WaveCrestPainter extends CustomPainter {
  final double crestY;
  final double arch;

  _WaveCrestPainter({required this.crestY, required this.arch});

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;

    // 1. Upward ambient glow leading into the teal background above the wave
    final double glowHeight = 80.0;
    final double glowTop = math.max(0.0, crestY - arch - glowHeight);
    final glowRect = Rect.fromLTRB(0, glowTop, w, crestY + 5.0);
    final glowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.28),
          Colors.white.withValues(alpha: 0.75),
        ],
        stops: const [0.0, 0.50, 1.0],
      ).createShader(glowRect);

    final glowPath = Path()
      ..moveTo(0, crestY - glowHeight)
      ..quadraticBezierTo(
        w * 0.5,
        crestY - arch - glowHeight,
        w,
        crestY - glowHeight,
      )
      ..lineTo(w, crestY)
      ..quadraticBezierTo(w * 0.5, crestY - arch, 0, crestY)
      ..close();
    canvas.drawPath(glowPath, glowPaint);

    // 2. Downward soft liquid sheen trailing onto the revealed home screen
    final double trailHeight = 50.0;
    final trailRect = Rect.fromLTRB(0, crestY - arch, w, crestY + trailHeight);
    final trailPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.75),
          Colors.white.withValues(alpha: 0.35),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.40, 1.0],
      ).createShader(trailRect);

    final trailPath = Path()
      ..moveTo(0, crestY)
      ..quadraticBezierTo(w * 0.5, crestY - arch, w, crestY)
      ..lineTo(w, crestY + trailHeight)
      ..lineTo(0, crestY + trailHeight)
      ..close();
    canvas.drawPath(trailPath, trailPaint);

    // 3. Fluid luminous wave line
    final waveCurve = Path()
      ..moveTo(0, crestY)
      ..quadraticBezierTo(w * 0.5, crestY - arch, w, crestY);

    // Outer soft glow stroke
    final glowStroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
    canvas.drawPath(waveCurve, glowStroke);

    // Core bright white highlight stroke
    final coreStroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(waveCurve, coreStroke);
  }

  @override
  bool shouldRepaint(covariant _WaveCrestPainter oldDelegate) {
    return oldDelegate.crestY != crestY || oldDelegate.arch != arch;
  }
}
