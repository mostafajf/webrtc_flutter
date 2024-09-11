import 'package:firebase_database/firebase_database.dart';

class PresenceService {
  final DatabaseReference presenceRef =
      FirebaseDatabase.instance.ref().child('presence');
  DatabaseReference? sessionRef;
  Future<void> setUserOnline(String userId) async {
    await presenceRef.child(userId).set({
      'state': 'online',
      'last_changed': ServerValue.timestamp,
    });
    presenceRef.child(userId).onDisconnect().remove();
  }

  Future<void> setUserOffline(String userId) async {
    await presenceRef.child(userId).remove();
  }
}
