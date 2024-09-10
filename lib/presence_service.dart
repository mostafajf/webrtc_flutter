import 'package:firebase_database/firebase_database.dart';

class PresenceService {
  final DatabaseReference presenceRef =
      FirebaseDatabase.instance.ref().child('presence');
  DatabaseReference? sessionRef;
  void setUserOnline(String userId) {
    var elRef = presenceRef.child(userId).push();
    sessionRef = elRef;
    elRef.child(userId).onDisconnect().remove();
  }

  void setUserOffline(String userId) {
    sessionRef?.remove();
  }

  Stream<bool> isUserOnline(String userId) {
    return presenceRef
        .child(userId)
        .onValue
        .map((event) => event.snapshot.value == true);
  }
}
