import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:firebase_core/firebase_core.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get/route_manager.dart';
import 'package:uuid/uuid.dart';

class VideoChatScreen extends StatefulWidget {
  @override
  _VideoChatScreenState createState() => _VideoChatScreenState();
}

class _VideoChatScreenState extends State<VideoChatScreen> {
  final webrtc.RTCVideoRenderer _localRenderer = webrtc.RTCVideoRenderer();
  final webrtc.RTCVideoRenderer _remoteRenderer = webrtc.RTCVideoRenderer();
  webrtc.RTCPeerConnection? _peerConnection;
  webrtc.MediaStream? _localStream;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String? _roomId;
  bool _isInitiator = false;
  var userId = Uuid().v4();
  TextEditingController idController = TextEditingController();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? userListener;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? candidatesListener;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? roomListener;
  bool isLoading = false;
  @override
  void initState() {
    super.initState();
    _initializeRenderers();
    _createPeerConnection();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _peerConnection?.dispose();
    userListener?.cancel();
    candidatesListener?.cancel();
    roomListener?.cancel();
    super.dispose();
  }

  Future<void> _initializeRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    // await _findUser();
  }

  void ListenUser() async {
    userListener ??= _firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .listen((event) async {
      var roomId = event.data()!['roomId'];
      if (roomId != "") {
        _roomId = roomId;
        setState(() {
          isLoading = false;
        });
        listenRoom();
      }
    });
  }

  void listenRoom() {
    if (_roomId != null) {
      roomListener ??= _firestore
          .collection('rooms')
          .doc(_roomId)
          .snapshots()
          .listen((event) {
        var data = event.data();
        if (data!.containsKey('initiator')) {
          var initiator = data['initiator'];
          if (initiator == userId) {
            _isInitiator = true;
          } else {
            _isInitiator = false;
          }
          offerOrAnswer();
        }
      });
    }
  }

  void offerOrAnswer() async {
    if (_isInitiator) {
      await _createOffer();
    } else {
      await _joinRoom();
    }
  }

  void listenCandidates() {
    if (candidatesListener != null && _roomId != null) {
      candidatesListener = _firestore
          .collection('rooms')
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
  }

  Future<void> _createPeerConnection() async {
    _localStream = await webrtc.navigator.mediaDevices.getUserMedia({
      'video': true,
      'audio': true,
    });

    _localRenderer.srcObject = _localStream;

    _peerConnection = await webrtc.createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    });

    _peerConnection?.onIceCandidate = (candidate) {
      if (candidate != null && _roomId != null) {
        _firestore
            .collection('rooms')
            .doc(_roomId)
            .collection('candidates')
            .add(candidate.toMap());
      }
    };

    _peerConnection?.onAddStream = (stream) {
      _remoteRenderer.srcObject = stream;
    };

    _peerConnection?.addStream(_localStream!);
  }

  Future<void> _findUser() async {
    try {
      setState(() {
        isLoading = true;
      });
      userId = idController.text;
      ListenUser();
      if (_roomId != null) return;
      final userQueueDocRef = _firestore.collection('queue').doc(userId);
      final userDocRef = _firestore.collection('users').doc(userId);
      final userqueueRef = _firestore.collection('queue').doc(userId);

      var timestamp = Timestamp.now();
      var userSnapshot = await userQueueDocRef.get();
      if (!userSnapshot.exists) {
        await userQueueDocRef
            .set({'userId': userId, 'lastUpdatedAt': timestamp});
      }
      if (_roomId != null) return;
      await userDocRef.set({'state': 'pending', 'roomId': ""});
      final findQuery = await _firestore
          .collection('queue')
          .orderBy('lastUpdatedAt')
          .where("userId", isNotEqualTo: userId)
          .limit(1)
          .get();
      if (findQuery.docs.isEmpty) {
        throw NotMatchException();
      }
      final queueDocs = findQuery.docs;

      final otherQueueUserDoc = queueDocs[0];
      final otherUser = otherQueueUserDoc.data();
      final otherUserId = otherQueueUserDoc.id;
      Timestamp otherUserLastUpdatedAt = otherUser['lastUpdatedAt'];
      if (timestamp.compareTo(otherUserLastUpdatedAt) < 0) {
        _isInitiator = true;
      } else {
        _isInitiator = false;
      }
      await _firestore.runTransaction((transaction) async {
        final userIds = [userId, otherUserId];
        userIds.sort();
        _roomId = userIds.join('_');
        final roomDocRef = _firestore.collection('rooms').doc(_roomId);
        final otherUserDocRef = _firestore.collection('users').doc(otherUserId);
        var otherUserQuery = await transaction.get(otherUserDocRef);
        final otherUserState = otherUserQuery.data()!['state'];
        if (otherUserState == 'busy') {
          if (_roomId != null) return;

          throw NotMatchException();
        }
        transaction.set(roomDocRef, {
          'initiator': _isInitiator ? userId : otherUserId,
          'receiver': _isInitiator ? otherUserId : userId,
        });
        transaction.set(userDocRef,
            {'state': 'busy', "roomId": _roomId, "initiator": _isInitiator});
        transaction.set(otherUserDocRef,
            {'state': 'busy', "roomId": _roomId, "initiator": !_isInitiator});
        transaction.delete(userqueueRef);
        transaction.delete(otherQueueUserDoc.reference);
        listenRoom();
      });
      if (_roomId!.isNotEmpty) {
        listenCandidates();
      }
    } on NotMatchException catch (e) {
      await _findUser();
    } catch (e) {
      print(e);
    }
  }

  Future<void> _createOffer() async {
    Get.snackbar("title", "message");
    webrtc.RTCSessionDescription description =
        await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(description);

    if (_roomId != null) {
      _firestore.collection('rooms').doc(_roomId).set({
        'offer': description.toMap(),
      }, SetOptions(merge: true));
    }
  }

  Future<void> _joinRoom() async {
    if (_roomId != null) {
      _firestore
          .collection('rooms')
          .doc(_roomId)
          .snapshots()
          .listen((roomSnapshot) async {
        final roomData = roomSnapshot.data();
        if (roomData!.isNotEmpty) {
          if (roomData.containsKey('offer')) {
            final offerData = roomData['offer'];
            webrtc.RTCSessionDescription offer = webrtc.RTCSessionDescription(
                offerData['sdp'], offerData['type']);
            await _peerConnection!.setRemoteDescription(offer);

            webrtc.RTCSessionDescription description =
                await _peerConnection!.createAnswer();
            await _peerConnection!.setLocalDescription(description);

            _firestore.collection('rooms').doc(_roomId).set({
              'answer': description.toMap(),
            }, SetOptions(merge: true));
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Video Chat')),
      body: Column(
        children: [
          Expanded(
            child: webrtc.RTCVideoView(_localRenderer),
          ),
          Expanded(
            child: webrtc.RTCVideoView(_remoteRenderer),
          ),
          TextField(controller: idController),
          isLoading
              ? CircularProgressIndicator()
              : ElevatedButton(
                  onPressed: _findUser,
                  child: Text('Find User'),
                ),
        ],
      ),
    );
  }
}

class NotMatchException implements Exception {
  NotMatchException();
}
