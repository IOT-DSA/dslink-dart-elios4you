import "dart:async";
import "dart:io";
import "dart:convert";

import "package:dslink/dslink.dart";
import "package:dslink/utils.dart";
import "package:dslink/nodes.dart";

class DataPoint {
  final String name;
  num value;
  String unit;

  DataPoint(this.name, [this.value, this.unit]);

  Stream get onUpdate => _controller.stream;
  StreamController _controller = new StreamController();
}

class Elios4YouClient {
  final String ip;
  final Map<String, DataPoint> points = {};
  final bool autoReconnect;

  Socket _socket;

  Elios4YouClient(this.ip, {this.autoReconnect: true});

  StreamController<DataPoint> _pointController = new StreamController();

  Stream<DataPoint> get onPointAdded => _pointController.stream;

  Disposable reconnectTimer;

  Future connect([int port = 5001]) async {
    if (_socket != null) {
      _socket.destroy();
    }

    _socket = await Socket.connect(ip, port).timeout(const Duration(seconds: 5));
    logger.info("Connected to client at ${ip}");
    _socket.transform(const Utf8Decoder()).transform(const LineSplitter()).listen((String line) {
      try {
        if (line.isEmpty) return;
        if (line[0] != ";") return;
        List<String> parts = line.split(";");
        String name = parts[1];
        num value = num.parse(parts[2]);
        String units = parts[3];

        if (points[name] is! DataPoint) {
          _pointController.add(points[name] = new DataPoint(name, value, units));
        } else {
          var point = points[name];
          point.value = value;
          point.unit = units;
          point._controller.add(null);
        }
      } catch (e) {}
    });

    var doneOrClose = ([e, s]) async {
      if (e != null && s != null) {
        logger.warning("Failed to reconnect to client at ip ${ip}", e, s);
      }

      if (reconnectTimer != null) {
        reconnectTimer.dispose();
        reconnectTimer = null;
      }

      reconnectTimer = Scheduler.safeEvery(Interval.TWO_SECONDS, () async {
        logger.info("Attempting Reconnect to client at ${ip}");
        try {
          await connect();

          if (reconnectTimer != null) {
            reconnectTimer.dispose();
            reconnectTimer = null;
          }
        } catch (e, stack) {
          logger.warning("Failed to reconnect to client at ip ${ip}", e, stack);
        }
      });
    };

    _socket.done.then(doneOrClose).catchError(doneOrClose);
  }

  void requestData() {
    if (_socket != null) {
      _socket.writeln("@dat\r");
    }
  }

  Future close() async {
    for (DataPoint point in points.values) {
      point._controller.close();
    }

    points.clear();
    _pointController.close();

    if (_socket != null) {
      _socket.destroy();
      _socket = null;
    }
  }
}

LinkProvider link;

class AddElios4YouNode extends SimpleNode {
  AddElios4YouNode(String path) : super(path);

  @override
  onInvoke(Map<String, dynamic> params) async {
    String name = params["name"];
    String rname = NodeNamer.createName(name);
    String ip = params["ip"];
    var node = link.getNode("/${rname}");
    if (node is Elios4YouNode) {
      throw new Exception("Client with name '${name}' already exists.");
    }

    if (ip is! String) {
      throw new Exception("IP not provided.");
    }

    link.addNode("/${rname}", {
      r"$is": "client",
      r"$name": name,
      "@ip": ip
    });

    link.save();
  }
}

class Elios4YouNode extends SimpleNode {
  String ip;
  Elios4YouClient client;

  Elios4YouNode(String path) : super(path);

  List<StreamSubscription> subs = [];

  Disposable dataTimer;

  @override
  onCreated() async {
    link.addNode("${path}/removeClient", {
      r"$name": "Remove Client",
      r"$invokable": "write",
      r"$is": "remove"
    });

    ip = attributes["@ip"];

    if (ip is! String) {
      remove();
      return;
    }

    client = new Elios4YouClient(ip);

    subs.add(client.onPointAdded.listen((DataPoint point) {
      String rname = NodeNamer.createName(point.name);
      SimpleNode node = link.getNode("${path}/${rname}");

      if (node != null && node.attributes["@marker"] != true) {
        link.removeNode("${path}/${rname}");
        node = null;
      }

      if (node == null) {
        node = link.addNode("${path}/${rname}", {
          r"$name": point.name,
          "@unit": point.unit,
          "?value": point.value,
          r"$type": "number",
          "@marker": true
        });
        node.serializable = false;
        logger.info("New Point for ${displayName}: ${point.name}");
      }

      subs.add(point.onUpdate.listen((e) {
        String oldUnit = node.attributes["@unit"];
        if (oldUnit != point.unit) {
          node.attributes["@unit"] = point.unit;
          node.updateList("@unit");
        }
        node.updateValue(point.value);
      }));
    }));

    dataTimer = Scheduler.safeEvery(Interval.ONE_SECOND, () {
      client.requestData();
    });

    try {
      await client.connect();
    } catch (e) {}
  }

  @override
  onRemoving() {
    while (subs.isNotEmpty) {
      subs.removeAt(0).cancel();
    }

    if (client != null) {
      client.close();
      client = null;
    }
  }
}

main(List<String> args) async {
  link = new LinkProvider(args, "Elios4You", autoInitialize: false, profiles: {
    "client": (String path) => new Elios4YouNode(path),
    "addClient": (String path) => new AddElios4YouNode(path),
    "remove": (String path) => new DeleteActionNode.forParent(path, link.provider as MutableNodeProvider)
  });
  link.init();

  link.addNode("/addClient", {
    r"$name": "Add Client",
    r"$invokable": "write",
    r"$params": [
      {
        "name": "name",
        "type": "string",
        "placeholder": "Client"
      },
      {
        "name": "ip",
        "type": "string",
        "placeholder": "192.168.2.50"
      }
    ],
    r"$is": "addClient"
  });
  link.connect();
}
