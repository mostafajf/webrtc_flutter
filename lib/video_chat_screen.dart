import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _initializeRenderers();
    _createPeerConnection();
    _findUser();
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

  void _findUser() async {
    final userId = Uuid().v4();
    if (userId != null) {
      final userDocRef = _firestore.collection('queue').doc(userId);

      await _firestore.runTransaction((transaction) async {
        final userSnapshot = await transaction.get(userDocRef);

        if (!userSnapshot.exists) {
          transaction
              .set(userDocRef, {'timestamp': FieldValue.serverTimestamp()});
        }
      });

      _firestore
          .collection('queue')
          .orderBy('timestamp')
          .limit(2)
          .snapshots()
          .listen((snapshot) async {
        if (_roomId != null) return;

        final queueDocs = snapshot.docs;
        if (queueDocs.length < 2) return;

        final userIds = queueDocs.map((doc) => doc.id).toList();
        if (userIds.contains(userId)) {
          final otherUserId = userIds.firstWhere((id) => id != userId);
          _roomId = _firestore.collection('rooms').doc().id;

          await _firestore.runTransaction((transaction) async {
            final roomDocRef = _firestore.collection('rooms').doc(_roomId);

            transaction.set(roomDocRef, {
              'initiator': userId,
              'receiver': otherUserId,
            });

            transaction.delete(queueDocs[0].reference);
            transaction.delete(queueDocs[1].reference);
          });

          setState(() {
            _isInitiator = userId == userIds[0];
          });

          if (_isInitiator) {
            _createOffer();
          } else {
            _joinRoom();
          }
        }
      });
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
