import socket
import sys
import time


def send_cmd(sock, cmd, arg=""):
    req = f"{cmd}:{arg}\n"
    print(f"-> {req.strip()}")
    sock.sendall(req.encode("utf-8"))

    # Wait for ACK
    resp = b""
    while not resp.endswith(b"\n"):
        chunk = sock.recv(1)
        if not chunk:
            break
        resp += chunk

    if resp:
        print(f"<- {resp.decode('utf-8').strip()}")


def main():
    sock_path = "/tmp/suckless_odin.sock"
    if len(sys.argv) > 1:
        sock_path = sys.argv[1]

    print(f"Connecting to automation socket: {sock_path}...")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    # Wait for server socket to become available
    connected = False
    for _ in range(50):
        try:
            sock.connect(sock_path)
            connected = True
            break
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.1)

    if not connected:
        print(f"Failed to connect to {sock_path}!")
        sys.exit(1)

    print("Connected.")

    send_cmd(sock, "AWAIT_INIT")
    send_cmd(sock, "LOAD_ENV", "next")
    send_cmd(sock, "LOAD_ENV", "next")
    send_cmd(sock, "QUIT")

    sock.close()


if __name__ == "__main__":
    main()
