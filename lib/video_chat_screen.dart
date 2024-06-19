import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

class VideoChatScreen extends StatefulWidget {
  @override
  _VideoChatScreenState createState() => _VideoChatScreenState();
}

class _VideoChatScreenState extends State<VideoChatScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String? _roomId;
  bool _isInitiator = false;
  final userId = Uuid().v4();
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
    super.dispose();
  }

  Future<void> _initializeRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    await _findUser();
  }

  Future<void> ListenUser() async {
    await _firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .listen((event) async {
      if (event.data()!['roomId'] != "") {
        _roomId = event.data()!['roomId'];
        await _createPeerConnection();
        if (_isInitiator) {
          await _createOffer();
        } else {
          await _joinRoom();
        }
      }
    });
  }

  Future<void> _createPeerConnection() async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'video': true,
      'audio': true,
    });

    _localRenderer.srcObject = _localStream;

    _peerConnection = await createPeerConnection({
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
      final userQueueDocRef = _firestore.collection('queue').doc(userId);
      final userDocRef = _firestore.collection('users').doc(userId);

      var timestamp = Timestamp.now();
      var userSnapshot = await userQueueDocRef.get();
      if (!userSnapshot.exists) {
        await userQueueDocRef.set({userId: userId, 'lastUpdatedAt': timestamp});
      }
      await userDocRef.set({'state': 'pending', 'roomId': ""});
      final findQuery = await _firestore
          .collection('queue')
          .orderBy('lastUpdatedAt')
          .where("userId", isNotEqualTo: userId)
          .limit(1)
          .get();
      if (_roomId != null) return;
      if (findQuery.docs.isEmpty) {
        throw NotMatchException();
      }
      final queueDocs = findQuery.docs;

      if (!userSnapshot.exists) {}
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
          throw NotMatchException();
        }
        transaction.set(roomDocRef, {
          'initiator': _isInitiator ? userId : otherUserId,
          'receiver': _isInitiator ? otherUserId : userId,
        });
        transaction.set(userDocRef, {'state': 'busy', "roomId": _roomId});
        transaction.set(otherUserDocRef, {'state': 'busy', "roomId": _roomId});
        transaction.delete(queueDocs[0].reference);
        transaction.delete(queueDocs[1].reference);
      });
    } on NotMatchException catch (e) {
      await _findUser();
    }
  }

  Future<void> _createOffer() async {
    RTCSessionDescription description = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(description);

    if (_roomId != null) {
      _firestore.collection('rooms').doc(_roomId).update({
        'offer': description.toMap(),
      });
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
        if (roomData != null) {
          if (roomData.containsKey('offer')) {
            final offerData = roomData['offer'];
            RTCSessionDescription offer =
                RTCSessionDescription(offerData['sdp'], offerData['type']);
            await _peerConnection!.setRemoteDescription(offer);

            RTCSessionDescription description =
                await _peerConnection!.createAnswer();
            await _peerConnection!.setLocalDescription(description);

            _firestore.collection('rooms').doc(_roomId).update({
              'answer': description.toMap(),
            });
          }

          _firestore
              .collection('rooms')
              .doc(_roomId)
              .collection('candidates')
              .snapshots()
              .listen((snapshot) {
            for (var change in snapshot.docChanges) {
              if (change.type == DocumentChangeType.added) {
                var data = change.doc.data();
                _peerConnection?.addCandidate(
                  RTCIceCandidate(data!['candidate'], data['sdpMid'],
                      data['sdpMLineIndex']),
                );
              }
            }
          });
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
            child: RTCVideoView(_localRenderer),
          ),
          Expanded(
            child: RTCVideoView(_remoteRenderer),
          ),
          ElevatedButton(
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
