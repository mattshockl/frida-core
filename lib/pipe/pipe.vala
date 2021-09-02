namespace Frida {
	public class PipeTransport : Object {
		public string local_address {
			get;
			construct;
		}

		public string remote_address {
			get;
			construct;
		}

		public void * _backend;

		public PipeTransport () throws Error {
			string local_address, remote_address;
			var backend = _create_backend (out local_address, out remote_address);
			Object (local_address: local_address, remote_address: remote_address);
			_backend = backend;
		}

		~PipeTransport () {
			_destroy_backend (_backend);
		}

		public extern static void set_temp_directory (string path);

		public extern static void * _create_backend (out string local_address, out string remote_address) throws Error;
		public extern static void _destroy_backend (void * backend);
	}

	namespace Pipe {
		public Future<IOStream> open (string address, Cancellable? cancellable) {
#if WINDOWS
			return WindowsPipe.open (address, cancellable);
#else
			return UnixPipe.open (address, cancellable);
#endif
		}
	}

#if WINDOWS
	public class WindowsPipe : IOStream {
		public string address {
			get;
			construct;
		}

		public void * backend {
			get;
			construct;
		}

		public MainContext main_context {
			get;
			construct;
		}

		public override InputStream input_stream {
			get {
				return input;
			}
		}

		public override OutputStream output_stream {
			get {
				return output;
			}
		}

		private InputStream input;
		private OutputStream output;

		public static Future<WindowsPipe> open (string address, Cancellable? cancellable) {
			var promise = new Promise<WindowsPipe> ();

			try {
				var pipe = new WindowsPipe (address);
				promise.resolve (pipe);
			} catch (IOError e) {
				promise.reject (e);
			}

			return promise.future;
		}

		public WindowsPipe (string address) throws IOError {
			var backend = _create_backend (address);

			Object (
				address: address,
				backend: backend,
				main_context: MainContext.get_thread_default ()
			);
		}

		construct {
			input = _make_input_stream (backend);
			output = _make_output_stream (backend);
		}

		~WindowsPipe () {
			_destroy_backend (backend);
		}

		public override bool close (Cancellable? cancellable = null) throws IOError {
			return _close_backend (backend);
		}

		protected extern static void * _create_backend (string address) throws IOError;
		protected extern static void _destroy_backend (void * backend);
		protected extern static bool _close_backend (void * backend) throws IOError;

		protected extern static InputStream _make_input_stream (void * backend);
		protected extern static OutputStream _make_output_stream (void * backend);
	}
#else
	namespace UnixPipe {
		public static Future<SocketConnection> open (string address, Cancellable? cancellable) {
			var promise = new Promise<SocketConnection> ();

#if DARWIN
			try {
				int fd = -1;
				int port_int = -1;
				GLib.Error cached_error = null;
				MatchInfo info;
				/*if (address.scanf ("pipe:port=0x%x", out port) == 1) {
					fd = _consume_stashed_file_descriptor (port);
				} else if (/^pipe:service=(.+?),uuid=(.+?)(,token=(.+))?$/.match (address, 0, out info)) {
					string service = info.fetch (1);
					string uuid = info.fetch (2);
					string? token = null;
					if (info.get_match_count () == 5)
						token = info.fetch (4);

					fd = _fetch_file_descriptor_from_service (service, uuid, token);
				}*/
				
				
				if (/^pipe:(service=([^,]+),uuid=([^,]+)(,token=([^,]+))?)?,?(port=([^,]+))?$/.match (address, 0, out info)) {
					string? service = info.fetch (2);
					string? uuid = info.fetch (3);
					string? token = info.fetch (5);
					string? port = info.fetch (7);

					if (service.length > 0 && uuid.length > 0) {
						if (token.length == 0)
							token = null;
						
						try {
							GLib.info("1\n");
							fd = _fetch_file_descriptor_from_service (service, uuid, token);
						} catch (GLib.Error e) {
							cached_error = e;
						}
					}

					// fetching from service failed, let's try port
					if (fd == -1 && port.scanf ("0x%x", out port_int) == 1) {
						try {
							GLib.info("2 %d\n", port_int);
							fd = _consume_stashed_file_descriptor (port_int);
						} catch (GLib.Error e) {
							cached_error = e;
						}
					}
					
					if (fd == -1 && cached_error != null) {
						GLib.info("3\n");
						throw cached_error;
					}
				}

				if (fd != -1) {
					var socket = new Socket.from_fd (fd);
					var connection = SocketConnection.factory_create_connection (socket);
					promise.resolve (connection);
					return promise.future;
				}
			} catch (GLib.Error e) {
				promise.reject (e);
				return promise.future;
			}
#endif

			MatchInfo info;
			bool valid_address = /^pipe:role=(.+?),path=(.+?)$/.match (address, 0, out info);
			assert (valid_address);
			string role = info.fetch (1);
			string path = info.fetch (2);

			try {
				UnixSocketAddressType type = UnixSocketAddress.abstract_names_supported ()
					? UnixSocketAddressType.ABSTRACT
					: UnixSocketAddressType.PATH;
				var server_address = new UnixSocketAddress.with_type (path, -1, type);

				if (role == "server") {
					var socket = new Socket (SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
					socket.bind (server_address, true);
					socket.listen ();

					Posix.chmod (path, Posix.S_IRUSR | Posix.S_IWUSR | Posix.S_IRGRP | Posix.S_IWGRP | Posix.S_IROTH | Posix.S_IWOTH);
#if ANDROID
					SELinux.setfilecon (path, "u:object_r:frida_file:s0");
#endif

					establish_server.begin (socket, server_address, promise, cancellable);
				} else {
					establish_client.begin (server_address, promise, cancellable);
				}
			} catch (GLib.Error e) {
				promise.reject (e);
			}

			return promise.future;
		}

		private async void establish_server (Socket socket, UnixSocketAddress address, Promise<SocketConnection> promise,
				Cancellable? cancellable) {
			var listener = new SocketListener ();
			try {
				listener.add_socket (socket, null);

				var connection = yield listener.accept_async (cancellable);
				promise.resolve (connection);
			} catch (GLib.Error e) {
				promise.reject (e);
			} finally {
				if (address.get_address_type () == PATH)
					Posix.unlink (address.get_path ());
				listener.close ();
			}
		}

		private async void establish_client (UnixSocketAddress address, Promise<SocketConnection> promise, Cancellable? cancellable) {
			var client = new SocketClient ();
			try {
				var connection = yield client.connect_async (address, cancellable);
				promise.resolve (connection);
			} catch (GLib.Error e) {
				promise.reject (e);
			}
		}

#if DARWIN
		public extern int _consume_stashed_file_descriptor (uint port) throws Error;
		public extern int _fetch_file_descriptor_from_service (string service, string uuid, string? token) throws Error;
#endif
	}
#endif
}

