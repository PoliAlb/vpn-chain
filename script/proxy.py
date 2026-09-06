import asyncio
import struct
import socket


async def inoltra(reader, writer):
    """Sposta i byte da 'reader' a 'writer' finché una delle due parti chiude."""
    try:
        while True:
            chunk = await reader.read(4096)
            if not chunk:
                break  # il socket è stato chiuso dall'altro lato
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        print(f"Connessione interrotta durante l'inoltro: {e}")
    finally:
        # Punto 5: chiudi il lato di scrittura quando questa direzione finisce,
        # cosi' l'altra direzione se ne accorge (il suo .read() torna b'') e si chiude a sua volta.
        try:
            writer.close()
            await writer.wait_closed()
        except OSError:
            pass  # può essere già stato chiuso dall'altra direzione


async def gestisci_connessione(local_reader, local_writer):
    remote_writer = None
    try:
        data = await local_reader.readexactly(8)
        version, command, port, ip_bytes = struct.unpack('!BBH4s', data)
        remote_ip = socket.inet_ntoa(ip_bytes)

        # 3. Controlla che versione sia 4 e comando sia 1
        if version != 4 or command != 1:
            local_writer.write(b'\x00\x5b\x00\x00\x00\x00\x00\x00')
            await local_writer.drain()
            return

        # 5. Apri la connessione verso l'esterno (Punto 6: gestione errore)
        try:
            remote_reader, remote_writer = await asyncio.open_connection(remote_ip, port)
        except (OSError, asyncio.TimeoutError) as e:
            print(f"Connessione remota fallita verso {remote_ip}:{port} -> {e}")
            local_writer.write(b'\x00\x5b\x00\x00\x00\x00\x00\x00')  # richiesta rifiutata/fallita
            await local_writer.drain()
            return

        # 6. Invia la risposta di successo al client
        local_writer.write(b'\x00\x5a\x00\x00\x00\x00\x00\x00')
        await local_writer.drain()

        # 7. Avvia i due task contemporanei
        task1 = asyncio.create_task(inoltra(local_reader, remote_writer))   # client -> remoto
        task2 = asyncio.create_task(inoltra(remote_reader, local_writer))  # remoto -> client
        await asyncio.gather(task1, task2, return_exceptions=True)

    except Exception as e:
        print(f"Errore: {e}")
    finally:
        local_writer.close()
        if remote_writer is not None:
            remote_writer.close()


async def main():
    server = await asyncio.start_server(gestisci_connessione, '0.0.0.0', 8080)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())
