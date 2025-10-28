import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraOcrPage(),
    );
  }
}

class CameraOcrPage extends StatefulWidget {
  const CameraOcrPage({super.key});
  @override
  State<CameraOcrPage> createState() => _CameraOcrPageState();
}

class _CameraOcrPageState extends State<CameraOcrPage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  late final TextRecognizer _textRecognizer;

  bool _isStreaming = false;
  bool _busy = false;
  String _overlayText = '';

  // 성능/발열 완화: 추론 주기(500ms)
  DateTime _lastInference = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _textRecognizer = TextRecognizer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _controller?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  // 앱 라이프사이클 대응
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _controller;
    if (cam == null) return;

    if (state == AppLifecycleState.inactive) {
      if (_isStreaming) {
        cam.stopImageStream();
        _isStreaming = false;
      }
      cam.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _reinitializeCamera();
    }
  }

  Future<void> _onStartPressed() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('설정 > 권한에서 카메라를 허용해 주세요.')));
      return;
    }
    await _reinitializeCamera();
    _startStream();
  }

  Future<void> _reinitializeCamera() async {
    final cameras = await availableCameras();
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21, // ✅ 여기!
    );

    _controller = controller;
    await controller.initialize();
    if (mounted) setState(() {});
  }

  void _startStream() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_isStreaming) return;

    _isStreaming = true;

    controller.startImageStream((CameraImage image) async {
      // 추론 빈도 제한
      final now = DateTime.now();
      if (now.difference(_lastInference) < const Duration(milliseconds: 500)) {
        return;
      }
      _lastInference = now;

      if (_busy) return;
      _busy = true;

      try {
        final inputImage = _buildInputImageFromCameraImage(
          image,
          controller.description,
        );

        final result = await _textRecognizer.processImage(inputImage);

        final buffer = StringBuffer();
        for (final block in result.blocks) {
          for (final line in block.lines) {
            buffer.writeln(line.text);
          }
        }
        final newText = buffer.toString().trim();

        if (kDebugMode && newText.isNotEmpty) {
          print('✅ 인식된 텍스트:\n$newText');
        }

        if (!mounted) return;
        setState(() => _overlayText = newText);
      } catch (e, st) {
        if (kDebugMode) {
          print('❌ OCR 실패: $e\n$st');
        }
      } finally {
        _busy = false;
      }
    });
  }

  void _stopStream() {
    if (!_isStreaming) return;
    _controller?.stopImageStream();
    _isStreaming = false;
  }

  InputImage _buildInputImageFromCameraImage(
    CameraImage image,
    CameraDescription description,
  ) {
    // ❌ (기존) 모든 plane 병합 X
    // ✅ NV21에서는 첫 번째 plane만 전달
    final bytes = image.planes[0].bytes;

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final rotation = _inputImageRotationFromCamera(
      description.sensorOrientation,
    );

    final metadata = InputImageMetadata(
      size: imageSize,
      rotation: rotation,
      format: InputImageFormat.nv21, // ✅ NV21로 명시
      bytesPerRow: image.planes[0].bytesPerRow, // ✅ plane[0]
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  /// 센서 각도(int) → MLKit 회전 열거형
  InputImageRotation _inputImageRotationFromCamera(int sensorOrientation) {
    switch (sensorOrientation) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasCam = _controller?.value.isInitialized == true;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('실시간 OCR 카메라')),
      body: Stack(
        children: [
          // 카메라 프리뷰
          Positioned.fill(
            child: hasCam
                ? CameraPreview(_controller!)
                : const Center(
                    child: Text(
                      '카메라 미실행',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
          ),
          // 텍스트 오버레이
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _overlayText.isEmpty ? 0 : 1,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _overlayText.isEmpty ? '인식된 텍스트가 여기에 표시됩니다.' : _overlayText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  label: const Text('카메라 시작'),
                  onPressed: _onStartPressed,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  label: const Text('중지'),
                  onPressed: () {
                    _stopStream();
                    setState(() => _overlayText = '');
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
