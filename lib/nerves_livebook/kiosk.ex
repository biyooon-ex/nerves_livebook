defmodule NervesLivebook.Kiosk do
  use Supervisor

  @runtime_dir "/run/kiosk"

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    File.mkdir_p!(@runtime_dir)
    File.chmod!(@runtime_dir, 0o700)

    children = [
      daemon(:udev, "exec udevd", []),
      daemon(
        :weston,
        """
        # Wait until udevd can respond to control requests
        until udevadm control --reload-rules; do
          sleep 1
        done

        # Register input devices that were connected before startup.
        udevadm trigger --type=subsystems --action=add
        udevadm trigger --type=devices --action=add
        udevadm settle --timeout=10

        # Detect the DRM card dynamically, since its number may change between boots
        while :; do
          card=""
          for status in /sys/class/drm/card*-DSI-*/status; do
            [ -f "$status" ] || continue
            [ "$(cat "$status")" = "connected" ] || continue

            connector="${status%/status}"
            connector="${connector##*/}"
            card="${connector%%-*}"
            break
          done

          [ -n "$card" ] && break
          sleep 1
        done

        exec weston \
          --backend=drm \
          --drm-device="$card" \
          --renderer=gl \
          --shell=kiosk-shell.so \
          --socket=wayland-0 \
          --idle-time=0 \
          --continue-without-input \
          --no-config
        """,
        [
          {"XDG_RUNTIME_DIR", @runtime_dir},
          {"LIBSEAT_BACKEND", "builtin"},
          {"SEATD_VTBOUND", "0"}
        ]
      ),
      daemon(
        :cog,
        """
        # Wait until Weston creates its Wayland socket
        until [ -S /run/kiosk/wayland-0 ]; do
          sleep 1
        done

        exec dbus-run-session -- \
          cog --platform=wl http://127.0.0.1/
        """,
        [
          {"XDG_RUNTIME_DIR", @runtime_dir},
          {"WAYLAND_DISPLAY", "wayland-0"}
        ]
      )
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 10
    )
  end

  defp daemon(id, script, env) do
    # Delay each start to avoid rapid restart loops on failure
    script = "set -eu\nsleep 2\n" <> script

    Supervisor.child_spec(
      {MuonTrap.Daemon,
       [
         "/bin/sh",
         ["-c", script],
         [
           env: env,
           stderr_to_stdout: true,
           log_output: :info,
           log_prefix: "#{id}: "
         ]
       ]},
      id: id,
      shutdown: 5_000
    )
  end
end
