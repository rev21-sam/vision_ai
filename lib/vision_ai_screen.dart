import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'main.dart';

class VisionAIScreen extends StatefulWidget {
  const VisionAIScreen({super.key});

  @override
  State<VisionAIScreen> createState() => _VisionAIScreenState();
}

class _VisionAIScreenState extends State<VisionAIScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isSwitchingCamera = false;
  bool _isPlayingAudio = false; // Add TTS playback state
  String _responseText = 'Tap Start to begin AI analysis';
  Timer? _analysisTimer;
  int _selectedInterval = 5; // Default 5 seconds
  final String _instruction = 'Describe what you see in this image clearly and concisely in 3-4 sentences. Focus on the main objects, people, and activities in the scene. If you see any brands, logos, labels, signs, or readable text, mention them specifically and clearly. Include important colors, settings, and context. Keep it conversational as this will be spoken aloud.';
  final String _openaiApiKey = ''; 
  bool _hasPermission = false;
  int _currentCameraIndex = 0; // 0 = back, 1 = front
  
  // Audio player for TTS
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  // ScrollController for auto-scrolling text
  final ScrollController _textScrollController = ScrollController();
  
  // Audio synchronization variables
  Timer? _scrollTimer;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;
  
  final List<int> _intervalOptions = [2, 3, 4, 5, 6, 7, 8, 9, 10];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAnalysis();
    _scrollTimer?.cancel();
    _audioPlayer.stop();
    _audioPlayer.dispose();
    _textScrollController.dispose();
    
    // Proper camera disposal to prevent hanging
    _disposeCameraController();
    
    super.dispose();
  }

  Future<void> _disposeCameraController() async {
    if (_cameraController != null) {
      print('Disposing camera controller...');
      
      try {
        // Immediate state update - don't wait for disposal
        final controller = _cameraController;
        _cameraController = null;
        
        if (mounted) {
          setState(() {
            _isCameraInitialized = false;
          });
        }
        
        // Don't even try to dispose properly - just abandon it
        // This completely avoids the finalizer thread pool issue
        print('Camera controller nullified immediately');
        
      } catch (e) {
        print('Camera disposal error: $e');
        _cameraController = null;
        if (mounted) {
          setState(() {
            _isCameraInitialized = false;
          });
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      // Stop analysis and audio first
      _stopAnalysis();
      _audioPlayer.stop();
      
      // Then dispose camera safely
      _disposeCameraController();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _requestPermissions() async {
    final cameraStatus = await Permission.camera.request();
    
    setState(() {
      _hasPermission = cameraStatus == PermissionStatus.granted;
    });

    if (_hasPermission) {
      await _initializeCamera();
    } else {
      setState(() {
        _responseText = 'Camera permission denied. Please grant permission in settings.';
      });
    }
  }

  Future<void> _initializeCamera() async {
    // Prevent multiple simultaneous initializations
    if (_isSwitchingCamera) return;
    
    print('Starting regular camera initialization...');
    
    try {
      // Get available cameras first
      cameras = await availableCameras();
    } catch (e) {
      setState(() {
        _responseText = 'Error accessing cameras: ${e.toString()}';
      });
      return;
    }

    if (cameras.isEmpty) {
      setState(() {
        _responseText = 'No cameras available on this device.';
      });
      return;
    }

    // Ensure current camera index is valid
    if (_currentCameraIndex >= cameras.length) {
      _currentCameraIndex = 0;
    }

    try {
      // Clean disposal first
      await _disposeCameraController();
      
      // Wait for cleanup
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Only proceed if still mounted and no controller exists
      if (!mounted || _cameraController != null) return;
      
      _cameraController = CameraController(
        cameras[_currentCameraIndex],
        ResolutionPreset.medium,
        enableAudio: false,
      );

      print('Initializing camera: ${cameras[_currentCameraIndex].name}');

      // Initialize with timeout
      await _cameraController!.initialize().timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          throw TimeoutException('Camera initialization timeout', const Duration(seconds: 8));
        },
      );

      if (mounted && _cameraController != null) {
        setState(() {
          _isCameraInitialized = true;
          _responseText = 'Camera ready. Tap Start to begin AI analysis.';
        });
        print('Regular camera initialization successful');
      }
    } catch (e) {
      // Clean up on initialization failure
      await _disposeCameraController();
      
      if (mounted) {
        setState(() {
          _responseText = 'Failed to initialize camera: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    if (cameras.length <= 1 || _isSwitchingCamera) return;
    
    print('=== STARTING CAMERA SWITCH ===');
    
    setState(() {
      _isSwitchingCamera = true;
      _isCameraInitialized = false;
    });

    try {
      // Wrap entire switch process in timeout
      await _performCameraSwitchWithTimeout().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          print('CAMERA SWITCH OUTER TIMEOUT');
          throw TimeoutException('Camera switch process timeout', const Duration(seconds: 15));
        },
      );
      
    } catch (e) {
      print('=== CAMERA SWITCH FAILED: $e ===');
      if (mounted) {
        setState(() {
          _responseText = 'Camera switch timed out or failed: ${e.toString()}';
        });
      }
      
      // Force cleanup on timeout/failure
      await _emergencyCleanup();
      
    } finally {
      if (mounted) {
        setState(() {
          _isSwitchingCamera = false;
        });
      }
      print('=== CAMERA SWITCH PROCESS ENDED ===');
    }
  }

  Future<void> _performCameraSwitchWithTimeout() async {
    // Stop any ongoing analysis immediately
    if (_isProcessing) {
      print('Stopping analysis...');
      _stopAnalysis();
    }

    // Complete camera system reset
    print('Starting camera reset...');
    await _completeCameraReset();

    // Update camera index
    _currentCameraIndex = (_currentCameraIndex + 1) % cameras.length;
    print('=== SWITCHING TO CAMERA INDEX: $_currentCameraIndex ===');
    
    // Get camera info before switching
    if (cameras.isNotEmpty && _currentCameraIndex < cameras.length) {
      final targetCamera = cameras[_currentCameraIndex];
      print('Target camera: ${targetCamera.name}, Facing: ${targetCamera.lensDirection}');
    }
    
    // Wait longer for complete system reset
    print('Waiting for system reset...');
    await Future.delayed(const Duration(milliseconds: 1500));
    
    // Initialize new camera with retries and timeout
    print('Starting camera initialization...');
    await _initializeCameraWithTimeoutProtection();
  }

  Future<void> _completeCameraReset() async {
    print('Starting complete camera reset...');
    
    // Nuclear disposal
    if (_cameraController != null) {
      _cameraController = null;
      print('Camera controller nullified');
    }
    
    // Force state reset
    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
      });
    }
    
    // Wait for system cleanup
    await Future.delayed(const Duration(milliseconds: 500));
    print('Camera reset complete');
  }

  Future<void> _initializeCameraWithTimeoutProtection() async {
    const maxRetries = 2; // Reduced retries to fail faster
    
    for (int retry = 0; retry < maxRetries; retry++) {
      try {
        print('>>> Camera initialization attempt ${retry + 1}/$maxRetries');
        
        // Wrap each attempt in its own timeout
        await _performSingleCameraInitialization().timeout(
          const Duration(seconds: 8),
          onTimeout: () {
            print('CAMERA INIT ATTEMPT TIMEOUT');
            throw TimeoutException('Camera initialization attempt timeout', const Duration(seconds: 8));
          },
        );
        
        // If we get here, initialization succeeded
        return;
        
      } catch (e) {
        print('>>> Camera initialization attempt ${retry + 1} FAILED: $e');
        
        // Clean up failed attempt
        await _emergencyCleanup();
        
        if (retry < maxRetries - 1) {
          // Wait before retry
          print('Waiting before retry...');
          await Future.delayed(const Duration(milliseconds: 2000));
        } else {
          // Final failure
          if (mounted) {
            setState(() {
              _responseText = 'Failed to initialize camera after $maxRetries attempts: ${e.toString()}';
            });
          }
          throw e; // Re-throw to trigger outer timeout
        }
      }
    }
  }

  Future<void> _performSingleCameraInitialization() async {
    // Get available cameras first
    print('Getting available cameras...');
    cameras = await availableCameras();
    print('Found ${cameras.length} cameras');
    
    if (cameras.isEmpty) {
      setState(() {
        _responseText = 'No cameras available on this device.';
      });
      return;
    }

    // Ensure current camera index is valid
    if (_currentCameraIndex >= cameras.length) {
      _currentCameraIndex = 0;
    }

    // Ensure no existing controller
    if (_cameraController != null) {
      print('Clearing existing controller...');
      _cameraController = null;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    
    print('Creating new camera controller...');
    final targetCamera = cameras[_currentCameraIndex];
    print('Target: ${targetCamera.name}, Direction: ${targetCamera.lensDirection}');
    
    // Create new controller
    _cameraController = CameraController(
      targetCamera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    print('>>> Calling initialize() for ${targetCamera.lensDirection}...');

    // Initialize with shorter timeout for individual operation
    await _cameraController!.initialize().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        print('>>> Camera initialize() TIMEOUT after 5 seconds');
        throw TimeoutException('Camera initialization timeout', const Duration(seconds: 5));
      },
    );

    print('>>> Camera initialize() SUCCESS!');

    if (mounted && _cameraController != null) {
      setState(() {
        _isCameraInitialized = true;
        _responseText = 'Camera ready. Tap Start to begin AI analysis.';
      });
      print('>>> Camera initialization COMPLETE');
    }
  }

  Future<void> _emergencyCleanup() async {
    print('EMERGENCY CLEANUP');
    _cameraController = null;
    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
      });
    }
  }

  Future<void> _waitForAudioCompletion() async {
    final completer = Completer<void>();
    
    StreamSubscription? subscription;
    subscription = _audioPlayer.onPlayerStateChanged.listen((PlayerState state) {
      if (state == PlayerState.completed || state == PlayerState.stopped) {
        subscription?.cancel();
        completer.complete();
      }
    });

    return completer.future;
  }

  // Auto-scroll to bottom of text field
  Future<void> _autoScrollToBottom() async {
    if (!mounted || !_textScrollController.hasClients) return;
    
    try {
      // Wait a bit for the text to render
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Check if we still have clients and the widget is mounted
      if (!mounted || !_textScrollController.hasClients) return;
      
      // Only scroll if there is content to scroll to
      if (_textScrollController.position.maxScrollExtent > 0) {
        // Animate scroll to bottom with smooth easing
        await _textScrollController.animateTo(
          _textScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      }
    } catch (e) {
      // Silently handle any scroll-related errors
      print('Auto-scroll error: $e');
    }
  }

  // Progressive scroll synchronized with audio playback
  void _startProgressiveScroll() {
    _scrollTimer?.cancel();
    
    print('Starting progressive scroll - Duration: $_audioDuration');
    
    if (!mounted || !_textScrollController.hasClients || _audioDuration == Duration.zero) {
      print('Cannot start scroll - mounted: $mounted, hasClients: ${_textScrollController.hasClients}, duration: $_audioDuration');
      return;
    }

    // Reset scroll position to top
    _textScrollController.jumpTo(0);
    
    // Calculate total scroll distance
    final maxScrollExtent = _textScrollController.position.maxScrollExtent;
    print('Max scroll extent: $maxScrollExtent');
    
    if (maxScrollExtent <= 0) {
      print('No scrollable content');
      return;
    }

    // Start progressive scrolling with more frequent updates for smoother motion
    const updateInterval = Duration(milliseconds: 100);
    _scrollTimer = Timer.periodic(updateInterval, (timer) async {
      if (!mounted || !_textScrollController.hasClients || !_isPlayingAudio) {
        print('Stopping scroll timer - mounted: $mounted, hasClients: ${_textScrollController.hasClients}, playing: $_isPlayingAudio');
        timer.cancel();
        return;
      }

      try {
        // Get current audio position
        final currentPosition = await _audioPlayer.getCurrentPosition();
        if (currentPosition == null) {
          print('No current position available');
          return;
        }

        // Calculate scroll progress (0.0 to 1.0)
        final progress = currentPosition.inMilliseconds / _audioDuration.inMilliseconds;
        final clampedProgress = progress.clamp(0.0, 1.0);

        // Calculate target scroll position
        final targetScrollPosition = maxScrollExtent * clampedProgress;

        print('Scroll progress: ${(clampedProgress * 100).toStringAsFixed(1)}% - Position: ${targetScrollPosition.toStringAsFixed(1)}');

        // Smooth scroll to position with very gentle animation
        if (_textScrollController.hasClients) {
          _textScrollController.animateTo(
            targetScrollPosition,
            duration: const Duration(milliseconds: 50),
            curve: Curves.linear,
          );
        }

        // Stop when audio is complete
        if (clampedProgress >= 1.0) {
          print('Scroll complete');
          timer.cancel();
        }
      } catch (e) {
        print('Progressive scroll error: $e');
        timer.cancel();
      }
    });
  }

  // Stop progressive scrolling
  void _stopProgressiveScroll() {
    _scrollTimer?.cancel();
  }

  // Quick scroll for non-audio updates
  Future<void> _quickScrollToBottom() async {
    if (!mounted || !_textScrollController.hasClients) return;
    
    try {
      await Future.delayed(const Duration(milliseconds: 50));
      
      if (!mounted || !_textScrollController.hasClients) return;
      
      if (_textScrollController.position.maxScrollExtent > 0) {
        await _textScrollController.animateTo(
          _textScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      print('Quick scroll error: $e');
    }
  }

  Future<void> _captureAndAnalyze() async {
    // Enhanced safety checks
    if (!_isCameraInitialized || 
        _cameraController == null || 
        _isPlayingAudio || 
        _isSwitchingCamera ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    try {
      // Double-check camera state before capture
      if (!_cameraController!.value.isInitialized) {
        print('Camera not initialized, skipping capture');
        return;
      }
      
      // Add timeout to prevent hanging during image capture
      final XFile image = await _cameraController!.takePicture().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Camera capture timeout', const Duration(seconds: 5));
        },
      );
      
      final Uint8List imageBytes = await image.readAsBytes();
      final String base64Image = 'data:image/jpeg;base64,${base64Encode(imageBytes)}';

      final response = await _sendToAI(base64Image);
      
      if (mounted) {
        setState(() {
          _responseText = response;
        });

        // Reset to top position for new text (no quick scroll)
        if (_textScrollController.hasClients) {
          _textScrollController.jumpTo(0);
        }

        // Convert response to speech and play
        await _speakText(response);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _responseText = 'Error capturing image: ${e.toString()}';
        });
        
        // Reset to top position for error messages too
        if (_textScrollController.hasClients) {
          _textScrollController.jumpTo(0);
        }
      }
    }
  }

  Future<String> _sendToAI(String base64Image) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_openaiApiKey',
        },
        body: jsonEncode({
          'model': 'gpt-4o',
          'max_tokens': 200,
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': _instruction,
                },
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': base64Image,
                  },
                },
              ],
            },
          ],
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['choices'][0]['message']['content'];
      } else {
        return 'OpenAI Vision API Error: ${response.statusCode} - ${response.body}';
      }
    } catch (e) {
      return 'OpenAI Vision Network Error: ${e.toString()}';
    }
  }

  Future<void> _speakText(String text) async {
    if (text.isEmpty || _isPlayingAudio) return;

    try {
      setState(() {
        _isPlayingAudio = true;
      });

      print('Starting TTS for text: ${text.substring(0, text.length > 50 ? 50 : text.length)}...');

      // Call OpenAI TTS API
      final audioBytes = await _textToSpeech(text);
      
      if (audioBytes != null) {
        // Save audio to temporary file
        final tempDir = await getTemporaryDirectory();
        final audioFile = File('${tempDir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
        await audioFile.writeAsBytes(audioBytes);

        print('Audio file created: ${audioFile.path}, size: ${audioBytes.length} bytes');

        // Play audio
        await _audioPlayer.play(DeviceFileSource(audioFile.path));
        
        // Get audio duration with retry logic
        _audioDuration = Duration.zero;
        for (int i = 0; i < 10; i++) {
          _audioDuration = await _audioPlayer.getDuration() ?? Duration.zero;
          if (_audioDuration > Duration.zero) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }
        
        print('Audio duration detected: $_audioDuration');
        
        if (_audioDuration > Duration.zero) {
          // Wait a moment for the text to render fully
          await Future.delayed(const Duration(milliseconds: 300));
          print('Starting progressive scroll...');
          _startProgressiveScroll();
        } else {
          print('No audio duration detected - skipping scroll');
        }
        
        // Wait for audio to complete
        await _waitForAudioCompletion();
        
        // Stop progressive scrolling
        _stopProgressiveScroll();
        
        // Clean up temp file
        try {
          await audioFile.delete();
        } catch (e) {
          print('Error deleting temp file: $e');
        }
      } else {
        print('No audio bytes received from TTS');
      }
    } catch (e) {
      print('TTS Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isPlayingAudio = false;
        });
        
        // Stop progressive scrolling when speech ends
        _stopProgressiveScroll();
      }
    }
  }

  Future<Uint8List?> _textToSpeech(String text) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/audio/speech'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_openaiApiKey',
        },
        body: jsonEncode({
          'model': 'gpt-4o-mini-tts',
          'input': text,
          'voice': 'nova',
          'response_format': 'mp3',
          'speed': 1.25, // Make speech 25% faster
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return response.bodyBytes;
      } else {
        print('OpenAI TTS API Error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      print('OpenAI TTS Network Error: $e');
      return null;
    }
  }

  void _startAnalysis() {
    if (!_isCameraInitialized) return;

    setState(() {
      _isProcessing = true;
      _responseText = 'Starting AI analysis...';
    });

    // Reset to top position when starting analysis
    if (_textScrollController.hasClients) {
      _textScrollController.jumpTo(0);
    }

    // Initial analysis
    _performAnalysisWithTimer();
  }

  void _performAnalysisWithTimer() async {
    // Perform the analysis
    await _captureAndAnalyze();
    
    // If still processing and not currently playing audio, schedule next analysis
    if (_isProcessing && !_isPlayingAudio) {
      _analysisTimer = Timer(
        Duration(seconds: _selectedInterval),
        _performAnalysisWithTimer,
      );
    }
  }

  void _stopAnalysis() {
    // Cancel all timers immediately
    _analysisTimer?.cancel();
    _analysisTimer = null;
    _scrollTimer?.cancel();
    
    // Stop any playing audio and progressive scrolling immediately
    try {
      _audioPlayer.stop();
    } catch (e) {
      print('Error stopping audio: $e');
    }
    
    _stopProgressiveScroll();
    
    // Update state
    if (mounted) {
      setState(() {
        _isProcessing = false;
        _isPlayingAudio = false;
        if (_responseText == 'Starting AI analysis...') {
          _responseText = 'Analysis stopped.';
        }
      });

      // Reset to top position when stopping analysis
      if (_textScrollController.hasClients) {
        try {
          _textScrollController.jumpTo(0);
        } catch (e) {
          print('Error resetting scroll position: $e');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 0,
        automaticallyImplyLeading: false,
      ),
      body: Stack(
        children: [
          // Full-screen camera preview
          if (_isCameraInitialized && _cameraController != null && !_isSwitchingCamera)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _cameraController!.value.previewSize!.height,
                  height: _cameraController!.value.previewSize!.width,
                  child: CameraPreview(_cameraController!),
                ),
              ),
            )
          else
            Container(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isSwitchingCamera)
                      const CircularProgressIndicator(
                        color: Colors.white,
                      )
                    else
                      Icon(
                        Icons.camera_alt_outlined,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                    const SizedBox(height: 16),
                    Text(
                      _isSwitchingCamera
                          ? 'Switching camera...'
                          : _hasPermission
                              ? 'Initializing camera...'
                              : 'Camera permission required',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Top overlay - Only camera switch button
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 16,
            child: cameras.length > 1
                ? GestureDetector(
                    onTap: _isSwitchingCamera ? null : _switchCamera,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _isSwitchingCamera ? Colors.black26 : Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.flip_camera_ios,
                        color: _isSwitchingCamera ? Colors.grey : Colors.white,
                        size: 24,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // AI Response overlay - Center of screen
          Positioned(
            left: 16,
            right: 16,
            top: MediaQuery.of(context).size.height * 0.2,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 350),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _isPlayingAudio ? Colors.blue.withOpacity(0.6) : Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _isPlayingAudio ? Colors.blue.withOpacity(0.7) : Colors.white.withOpacity(0.25),
                  width: _isPlayingAudio ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isPlayingAudio)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.volume_up,
                          color: Colors.white,
                          size: 24,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Speaking...',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  if (_isPlayingAudio) const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      controller: _textScrollController,
                      physics: const BouncingScrollPhysics(),
                      child: Text(
                        _responseText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          height: 1.5,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bottom controls overlay
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Interval selector
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Interval:',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: _selectedInterval,
                            dropdownColor: Colors.black87,
                            style: const TextStyle(color: Colors.white),
                            onChanged: _isProcessing
                                ? null
                                : (int? newValue) {
                                    if (newValue != null) {
                                      setState(() {
                                        _selectedInterval = newValue;
                                      });
                                    }
                                  },
                            items: _intervalOptions.map<DropdownMenuItem<int>>((int value) {
                              return DropdownMenuItem<int>(
                                value: value,
                                child: Text('${value}s'),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Start/Stop button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isCameraInitialized
                        ? (_isProcessing ? _stopAnalysis : _startAnalysis)
                        : null,
                    icon: Icon(_isProcessing ? Icons.stop : Icons.play_arrow),
                    label: Text(
                      _isProcessing ? 'Stop Analysis' : 'Start Analysis',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isProcessing ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
} 