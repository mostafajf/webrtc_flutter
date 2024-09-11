import 'dart:async';
import 'dart:developer';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'dart:developer' as developer;

import 'package:webrtc_flutter/presence_service.dart';

class VideoChatScreen extends StatefulWidget {
  const VideoChatScreen({Key? key}) : super(key: key);

  @override
  _VideoChatScreenState createState() => _VideoChatScreenState();
}

class _VideoChatScreenState extends State<VideoChatScreen>
    with WidgetsBindingObserver {
  final webrtc.RTCVideoRenderer _localRenderer = webrtc.RTCVideoRenderer();
  final webrtc.RTCVideoRenderer _remoteRenderer = webrtc.RTCVideoRenderer();
  webrtc.RTCPeerConnection? _peerConnection;
  webrtc.MediaStream? _localStream;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String _roomId = "";
  bool _isInitiator = false;
  var userId = const Uuid().v4();
  String otherUserId = "";
  TextEditingController idController = TextEditingController();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? userListener;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? otherListener;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? candidatesListener;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? roomListener;
  bool isLoading = false;
  bool isExpanded = true;
  AppLifecycleState? lifecycleState;
  final numOfBatches = 1;
  PresenceService presenceService = PresenceService();
  @override
  void initState() {
    super.initState();
    _initializeRenderers();
    WidgetsBinding.instance.addObserver(this);
    var countryCode = PlatformDispatcher.instance.locale.countryCode;
    developer.log('countryCode: $countryCode');
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _peerConnection?.dispose();
    userListener?.cancel();
    otherListener?.cancel();
    candidatesListener?.cancel();
    roomListener?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      presenceService.setUserOffline(userId);
    }
    setState(() {});
  }

  Future<void> _initializeRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    // await _findUser();
  }

  void listenUser() async {
    userListener ??= _firestore
        .collection('Users')
        .doc(userId)
        .snapshots()
        .listen((event) async {
      if (event.exists) {
        var user = event.data();
        if (user!['roomId'] != null) {
          _roomId = user['roomId'];
          setState(() {
            isLoading = false;
          });
          listenRoom();
        } else {
          _roomId = "";
        }
      }
    });
  }

  void listenOtherUser() async {
    otherListener ??= _firestore
        .collection('Users')
        .doc(otherUserId)
        .snapshots()
        .listen((event) async {
      if (event.exists) {
        var user = event.data();
        if (user?["isOnline"] == false) {
          isLoading = true;
          await restartProcess();
          isLoading = false;
        }
      }
    });
  }

  Future<void> listenRoom() {
    if (_roomId.isNotEmpty) {
      roomListener ??= _firestore
          .collection('Rooms')
          .doc(_roomId)
          .snapshots()
          .listen((event) async {
        var data = event.data();
        if (data!.containsKey('initiator')) {
          var initiator = data['initiator'];
          if (initiator == userId) {
            _isInitiator = true;
          } else {
            _isInitiator = false;
            otherUserId = initiator;
          }
          await offerOrAnswer(data);
          listenOtherUser();
          setState(() {
            isLoading = false;
          });
        }
      });
    }
    return Future.value();
  }

  Future<void> offerOrAnswer(Map<String, dynamic>? room) async {
    if (_isInitiator) {
      await _createOffer(room);
    } else {
      await _joinRoom(room);
    }
  }

  void listenCandidates() {
    candidatesListener ??= _firestore
        .collection('Rooms')
        .doc(_roomId)
        .collection('candidates')
        .snapshots()
        .listen((snapshot) {
      for (var change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          var data = change.doc.data();
          _peerConnection?.addCandidate(
            webrtc.RTCIceCandidate(
                data!['candidate'], data['sdpMid'], data['sdpMLineIndex']),
          );
        }
      }
    });
  }

  Future<void> _createPeerConnection() async {
    _localStream = await webrtc.navigator.mediaDevices.getUserMedia({
      'video': true,
      'audio': true,
    });

    _localRenderer.srcObject = _localStream;

    _peerConnection = await webrtc.createPeerConnection({
      'iceServers': [
        {
          'urls': [
            'stun:stun1.l.google.com:19302',
            'stun:stun2.l.google.com:19302'
          ]
        },
      ]
    });

    _peerConnection?.onIceCandidate = (candidate) {
      if (_roomId.isNotEmpty) {
        _firestore
            .collection('Rooms')
            .doc(_roomId)
            .collection('candidates')
            .add(candidate.toMap());
        listenCandidates();
      }
    };

    _peerConnection?.onAddStream = (stream) {
      _remoteRenderer.srcObject = stream;
    };

    _peerConnection?.addStream(_localStream!);
    _peerConnection?.onSignalingState = (state) {
      developer.log('onSignalingState: $state');
    };
    // Listen for connection state changes
    _peerConnection?.onIceConnectionState = (RTCIceConnectionState state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        debugger();
        developer.log('ICE connection state: $state');
      }
    };

    _peerConnection?.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        developer.log('Peer connection state: $state');
      }
    };
  }

  Future<void> _findUser() async {
    try {
      setState(() {
        isLoading = true;
      });
      userId = idController.text;
      await presenceService.setUserOnline(userId);
      _createPeerConnection();

      listenUser();
      final randomBtach = Random().nextInt(numOfBatches) + 1;
      final userQueueDocRef = _firestore
          .collection("Batches")
          .doc("batch$randomBtach")
          .collection('Queue')
          .doc(userId);
      var timestamp = Timestamp.now();
      await userQueueDocRef.set({'userId': userId, 'lastUpdatedAt': timestamp});
      // ignore: empty_catches
    } catch (e) {
      print(e);
    }
  }

  Future<void> _createOffer(Map<String, dynamic>? room) async {
    if (!room!.containsKey('offer')) {
      webrtc.RTCSessionDescription description =
          await _peerConnection!.createOffer({'offerToReceiveVideo': 1});
      await _peerConnection!.setLocalDescription(description);
      await _firestore.collection('Rooms').doc(_roomId).set({
        'offer': description.toMap(),
      }, SetOptions(merge: true));
    } else if (room.containsKey('answer')) {
      final answerData = room['answer'];
      webrtc.RTCSessionDescription answer =
          webrtc.RTCSessionDescription(answerData['sdp'], answerData['type']);
      await _peerConnection!.setRemoteDescription(answer);
    }
  }

  Future<void> _joinRoom(Map<String, dynamic>? room) async {
    if (_roomId.isNotEmpty) {
      if (!room!.containsKey('answer')) {
        if (room.containsKey('offer')) {
          final offerData = room['offer'];
          webrtc.RTCSessionDescription offer =
              webrtc.RTCSessionDescription(offerData['sdp'], offerData['type']);
          await _peerConnection!.setRemoteDescription(offer);

          webrtc.RTCSessionDescription description =
              await _peerConnection!.createAnswer({'offerToReceiveVideo': 1});
          await _peerConnection!.setLocalDescription(description);

          _firestore.collection('Rooms').doc(_roomId).set({
            'answer': description.toMap(),
          }, SetOptions(merge: true));
          setState(() {});
        }
      }
    }
  }

  Future<void> restartProcess() async {
    var batch = _firestore.batch();
    final userDocRef = _firestore.collection('Users').doc(userId);
    final otherUserDocRef = _firestore.collection('Users').doc(otherUserId);
    final roomDocRef = _firestore.collection('Rooms').doc(_roomId);

    batch.set(userDocRef, {'status': 'available', 'roomId': null},
        SetOptions(merge: true));
    batch.set(otherUserDocRef, {'status': 'availabe', 'roomId': null},
        SetOptions(merge: true));
    batch.delete(roomDocRef);
    _roomId = "";
    _remoteRenderer.srcObject = null;
    roomListener?.cancel();
    roomListener = null;
    await batch.commit();
  }

  void _toggleExpand() {
    setState(() {
      isExpanded = !isExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Stack(
        children: [
          if (isExpanded) ...[
            largePositionedVideo(context, webrtc.RTCVideoView(_localRenderer)),
            smallPositionedVideo(context, webrtc.RTCVideoView(_remoteRenderer)),
          ] else ...[
            largePositionedVideo(context, webrtc.RTCVideoView(_remoteRenderer)),
            smallPositionedVideo(context, webrtc.RTCVideoView(_localRenderer)),
          ],
          Column(
            children: [
              TextField(
                controller: idController,
                style: const TextStyle(color: Colors.white),
              ),
              isLoading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _findUser,
                      child: const Text('Find User'),
                    ),
              Text(
                otherUserId,
                style: const TextStyle(color: Colors.white, fontSize: 20),
              ),
              Text(lifecycleState.toString(),
                  style: const TextStyle(color: Colors.white)),
            ],
          )
        ],
      ),
    );
  }

  Positioned smallPositionedVideo(BuildContext context, Widget widget) {
    return Positioned(
      top: 0,
      right: 0,
      left: MediaQuery.of(context).size.width / 1.3,
      bottom: MediaQuery.of(context).size.height / 1.5,
      child: GestureDetector(
        onTap: _toggleExpand,
        child: AbsorbPointer(
            child:
                Container(color: Colors.black, child: Expanded(child: widget))),
      ),
    );
  }

  Positioned largePositionedVideo(BuildContext context, Widget widget) {
    return Positioned(
      top: 0,
      right: 0,
      left: 0,
      bottom: 0,
      child: Container(color: Colors.black, child: Expanded(child: widget)),
    );
  }
}

class NotMatchException implements Exception {
  NotMatchException();
}
