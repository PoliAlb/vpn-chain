import asyncio
import socket
import struct

LISTEN_HOST = '0.0.0.0'
LISTEN_PORT = 8080

REPLY_OK = b'\x00\x5a\x00\x00\x00\x00\x00\x00'
REPLY_FAIL = b'\x00\x5b\x00\x00\x00\x00\x00\x00'


async def inoltra(reader, writer):
    """Sposta i byte da 'reader' a 'writer' finché una delle due parti chiude."""
    try:
        while True:
            chunk = await reader.read(4096)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        print(f"Connessione interrotta durante l'inoltro: {e}")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except OSError:
            pass


async def gestisci_connessione(local_reader, local_writer):
    remote_writer = None
    try:
        # Header SOCKS4: VN(1) CD(1) DSTPORT(2) DSTIP(4)
        data = await local_reader.readexactly(8)
        version, command, port, ip_bytes = struct.unpack('!BBH4s', data)

        # FIX 1: dopo l'header ci sono USERID (lunghezza variabile) + NUL.
        # Il codice originale non li leggeva: il NUL finiva nel flusso dati
        # e il server remoto vedeva "\x00GET ..." -> 501 / connessione rotta.
        await asyncio.wait_for(local_reader.readuntil(b'\x00'), timeout=10)

        if version != 4 or command != 1:
            local_writer.write(REPLY_FAIL)
            await local_writer.drain()
            return

        # FIX 2: SOCKS4a. Se l'IP è 0.0.0.x (x != 0) il client manda il
        # NOME HOST dopo lo userid, e la risoluzione DNS la facciamo qui,
        # DENTRO la VPN (niente DNS leak lato client).
        if ip_bytes[:3] == b'\x00\x00\x00' and ip_bytes[3] != 0:
            raw = await asyncio.wait_for(local_reader.readuntil(b'\x00'), timeout=10)
            remote_host = raw[:-1].decode('ascii', errors='replace')
        else:
            remote_host = socket.inet_ntoa(ip_bytes)

        try:
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(remote_host, port), timeout=15)
        except (OSError, asyncio.TimeoutError) as e:
            print(f"Connessione remota fallita verso {remote_host}:{port} -> {e!r}")
            local_writer.write(REPLY_FAIL)
            await local_writer.drain()
            return

        local_writer.write(REPLY_OK)
        await local_writer.drain()

        task1 = asyncio.create_task(inoltra(local_reader, remote_writer))
        task2 = asyncio.create_task(inoltra(remote_reader, local_writer))
        await asyncio.gather(task1, task2, return_exceptions=True)

    except (asyncio.IncompleteReadError, asyncio.TimeoutError, asyncio.LimitOverrunError):
        pass  # client che chiude/handshake incompleto: normale, niente rumore
    except Exception as e:
        print(f"Errore: {e!r}")
    finally:
        local_writer.close()
        if remote_writer is not None:
            remote_writer.close()


async def main():
    server = await asyncio.start_server(gestisci_connessione, LISTEN_HOST, LISTEN_PORT)
    print(f"SOCKS4/4a in ascolto su {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())