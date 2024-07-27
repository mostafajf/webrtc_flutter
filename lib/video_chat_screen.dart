import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:firebase_core/firebase_core.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get/get.dart';
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
  String _roomId = "";
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
      if (event.exists) {
        var user = event.data();
        if (user!['roomId'] != null) {
          _roomId = user['roomId'];
          setState(() {
            isLoading = false;
          });
          listenRoom();
        }
      }
    });
  }

  Future<void> listenRoom() {
    if (_roomId.isNotEmpty) {
      roomListener ??= _firestore
          .collection('rooms')
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
          }
          await offerOrAnswer(data);
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
            .collection('rooms')
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
  }

  Future<void> _findUser() async {
    try {
      setState(() {
        isLoading = true;
      });
      userId = idController.text;
      ListenUser();
      if (_roomId.isNotEmpty) {
        setState(() {
          isLoading = false;
        });
        return;
      }
      final userQueueDocRef = _firestore.collection('queue').doc(userId);
      final userDocRef = _firestore.collection('users').doc(userId);

      var timestamp = Timestamp.now();
      var userSnapshot = await userQueueDocRef.get();

      if (_roomId.isNotEmpty) return;

      final findQuery = await _firestore
          .collection('queue')
          .orderBy('lastUpdatedAt')
          .where("userId", isNotEqualTo: userId)
          .limit(1)
          .get();
      if (findQuery.docs.isEmpty) {
        if (!userSnapshot.exists && _roomId.isEmpty) {
          await userQueueDocRef
              .set({'userId': userId, 'lastUpdatedAt': timestamp});
        }
        throw NotMatchException();
      }
      final queueDocs = findQuery.docs;

      final otherQueueUserDoc = queueDocs[0];
      final otherUser = otherQueueUserDoc.data();
      final otherUserId = otherQueueUserDoc.id;
      // Timestamp otherUserLastUpdatedAt = otherUser['lastUpdatedAt'];
      if (otherUser["userId"].toString().compareTo(userId) <= 0) {
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
        if (otherUserQuery.exists) {
          final otherUserState = otherUserQuery.data()!['status'];
          if (otherUserState == 'busy') {
            if (_roomId.isNotEmpty) return;

            throw NotMatchException();
          }
        }
        transaction.set(roomDocRef, {
          'initiator': _isInitiator ? userId : otherUserId,
          'receiver': _isInitiator ? otherUserId : userId,
        });
        transaction.set(userDocRef,
            {'status': 'busy', "roomId": _roomId, "initiator": _isInitiator});
        transaction.set(otherUserDocRef,
            {'status': 'busy', "roomId": _roomId, "initiator": !_isInitiator});
        transaction.delete(userQueueDocRef);
        transaction.delete(otherQueueUserDoc.reference);
        listenRoom();
      }, timeout: Duration(seconds: 90));
    } on NotMatchException catch (e) {
      await _findUser();
    } catch (e, stackTrace) {
      print(e);
    }
  }

  Future<void> _createOffer(Map<String, dynamic>? room) async {
    if (!room!.containsKey('offer')) {
      webrtc.RTCSessionDescription description =
          await _peerConnection!.createOffer({'offerToReceiveVideo': 1});
      await _peerConnection!.setLocalDescription(description);
      await _firestore.collection('rooms').doc(_roomId).set({
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

          _firestore.collection('rooms').doc(_roomId).set({
            'answer': description.toMap(),
          }, SetOptions(merge: true));
          setState(() {});
        }
      }
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
