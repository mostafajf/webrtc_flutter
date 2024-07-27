import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:uuid/uuid.dart';
import 'package:webrtc_flutter/video_chat_screen.dart';
import 'firebase_options.dart';

void main() async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // Catch synchronous errors
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    Get.snackbar(
      'Error',
      details.exceptionAsString(),
      snackPosition: SnackPosition.TOP,
    );
    // Handle the error, e.g., log it to a server
    // or show a custom error UI
  };

  // Catch asynchronous errors
  runZonedGuarded(() {
    runApp(const MyApp());
  }, (error, stackTrace) {
    // Handle the error, e.g., log it to a server
    // or show a custom error UI
    print('Caught zoned error: $error');
    print('Stack trace: $stackTrace');
    Get.snackbar(
      'Error',
      error.toString(),
      snackPosition: SnackPosition.TOP,
    );
  });
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: VideoChatScreen(),
    );
  }
}
