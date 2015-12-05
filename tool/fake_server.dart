import "dart:io";
import "dart:convert";

main() async {
  var server = await ServerSocket.bind("0.0.0.0", 5001);
  int i = 0;
  server.listen((Socket socket) {
    socket.transform(const Utf8Decoder()).listen((data) {
      if (data == "@dat\r\n") {
        i++;
        socket.write(";Counter;${i};requests;\r\n");
      }
    });
  });
}
