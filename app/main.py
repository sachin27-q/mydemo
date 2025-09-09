from flask import Flask, jsonify
app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status":"ok"})

@app.route("/hello")
def hello():
    return jsonify({"message":"hello from demo1-471009"})
