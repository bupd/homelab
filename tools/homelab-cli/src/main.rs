use std::{
    env,
    fmt::Display,
    io::{self, IsTerminal},
    process::{Command as ProcessCommand, ExitCode, Output, Stdio},
};

use clap::{Parser, Subcommand};
use owo_colors::OwoColorize;

const ADMIN_BINARY: &str = "/usr/local/lib/homelab/homelab-admin";
const SUDO: &str = "/usr/bin/sudo";
const SYSTEMCTL: &str = "/usr/bin/systemctl";
const FINDMNT: &str = "/usr/bin/findmnt";
const SYNC: &str = "/usr/bin/sync";
const UMOUNT: &str = "/usr/bin/umount";
const MEDIA_MOUNT: &str = "/home/bupd/hdd/data";
const MEDIA_DEVICE: &str = "/dev/disk/by-uuid/ACCA4642CA460952";
const K3S: &str = "k3s.service";
const WORKER: &str = "media-worker.service";
const WORKER_ENSURE: &str = "media-worker-ensure.service";
const MEDIA_AUTOMOUNT: &str = "home-bupd-hdd-data.automount";
const MEDIA_MOUNT_UNIT: &str = "home-bupd-hdd-data.mount";
const MEDIA_PREFLIGHT: &str = "home-bupd-hdd-data-preflight.service";

type Result<T> = std::result::Result<T, String>;

#[derive(Parser, Debug)]
#[command(
    name = "homelab",
    version,
    about = "A calm on/off switch for the homelab",
    long_about = "Start or stop the complete K3s homelab safely.\n\nEvery command is idempotent: repeating it is safe."
)]
struct Cli {
    #[command(subcommand)]
    command: UserCommand,

    /// Internal: run the privileged half of a command.
    #[arg(long, hide = true)]
    run_as_admin: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Subcommand)]
enum UserCommand {
    /// Mount storage and start the K3s control plane and worker.
    Up,
    /// Stop every Kubernetes workload and release host resources.
    Down,
    /// Show service and storage state without changing anything.
    Status,
}

impl UserCommand {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Up => "up",
            Self::Down => "down",
            Self::Status => "status",
        }
    }
}

fn main() -> ExitCode {
    configure_color();

    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{} {error}", "error".red().bold());
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    if cli.run_as_admin {
        if !is_root() {
            return Err("the privileged helper must run as root".to_owned());
        }
        run_admin(cli.command)
    } else {
        run_client(cli.command)
    }
}

fn configure_color() {
    if !io::stdout().is_terminal() || env::var_os("NO_COLOR").is_some() {
        owo_colors::set_override(false);
    }
}

fn run_client(command: UserCommand) -> Result<()> {
    let status = ProcessCommand::new(SUDO)
        .args(["-n", ADMIN_BINARY, "--run-as-admin", command.as_str()])
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| format!("could not start the privileged helper: {error}"))?;

    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "homelab {} did not finish successfully",
            command.as_str()
        ))
    }
}

fn run_admin(command: UserCommand) -> Result<()> {
    heading(command);
    match command {
        UserCommand::Up => up(),
        UserCommand::Down => down(),
        UserCommand::Status => status(),
    }
}

fn up() -> Result<()> {
    start_mount()?;
    ensure_service(K3S, DesiredState::Running)?;
    ensure_service(WORKER, DesiredState::Running)?;
    success("Homelab is online. Kubernetes workloads can run.");
    Ok(())
}

fn down() -> Result<()> {
    // The worker owns every Pod and consumes the media mount. Stop it before
    // the control plane so workloads receive a normal termination signal.
    ensure_service(WORKER_ENSURE, DesiredState::Stopped)?;
    ensure_service(WORKER, DesiredState::Stopped)?;
    ensure_service(K3S, DesiredState::Stopped)?;
    flush_and_unmount_media_disk()?;
    success("Homelab is offline. The media disk is unmounted.");
    Ok(())
}

fn status() -> Result<()> {
    print_service_status("K3s control plane", K3S)?;
    print_service_status("K3s media worker", WORKER)?;
    let mounted = command_success(SYSTEMCTL, &["is-active", "--quiet", MEDIA_MOUNT_UNIT])?;
    let state = if mounted {
        "mounted".green().to_string()
    } else {
        "not mounted".yellow().to_string()
    };
    println!("  {:<20} {state}", "Media disk");
    Ok(())
}

fn start_mount() -> Result<()> {
    ensure_service(MEDIA_AUTOMOUNT, DesiredState::Running)?;
    if command_success(SYSTEMCTL, &["is-active", "--quiet", MEDIA_MOUNT_UNIT])? {
        step(
            format!("Media disk is already mounted at {MEDIA_MOUNT}"),
            StepState::Skipped,
        );
        return Ok(());
    }

    // A prior failed preflight must not block a later clean mount attempt.
    run_success(
        SYSTEMCTL,
        &["reset-failed", MEDIA_PREFLIGHT, MEDIA_MOUNT_UNIT],
    )?;
    step("Mounting the media disk", StepState::Working);
    run_success(SYSTEMCTL, &["start", MEDIA_MOUNT_UNIT])
        .map_err(|error| format!("could not mount {MEDIA_MOUNT}: {error}"))?;
    if !command_success(SYSTEMCTL, &["is-active", "--quiet", MEDIA_MOUNT_UNIT])? {
        return Err(format!("{MEDIA_MOUNT} did not become an active mount"));
    }
    step(
        format!("Media disk is mounted at {MEDIA_MOUNT}"),
        StepState::Done,
    );
    Ok(())
}

fn flush_and_unmount_media_disk() -> Result<()> {
    step("Flushing pending disk writes", StepState::Working);
    run_success(SYNC, &[])?;
    step("Pending disk writes are flushed", StepState::Done);

    // Stop the automounter first so no new access can immediately remount the
    // disk between the unmount and a later homelab up.
    ensure_service(MEDIA_AUTOMOUNT, DesiredState::Stopped)?;
    ensure_service(MEDIA_MOUNT_UNIT, DesiredState::Stopped)?;

    // K3s uses shared submounts for Pods. Stopping the container can leave
    // those submounts behind, even when the parent systemd mount is inactive.
    // Unmount every target backed by this exact partition, without force or
    // lazy-detach behavior, so the next NTFS preflight sees a clean device.
    if media_device_has_mounts()? {
        step(
            "Unmounting remaining media-disk submounts",
            StepState::Working,
        );
        run_success(UMOUNT, &["--all-targets", MEDIA_DEVICE])?;
        step(
            "Remaining media-disk submounts are unmounted",
            StepState::Done,
        );
    }

    if media_device_has_mounts()? {
        return Err(format!("{MEDIA_DEVICE} is still mounted; it may be in use"));
    }
    Ok(())
}

fn media_device_has_mounts() -> Result<bool> {
    let output = ProcessCommand::new(FINDMNT)
        .args([
            "--raw",
            "--noheadings",
            "--output",
            "TARGET",
            "--source",
            MEDIA_DEVICE,
        ])
        .output()
        .map_err(|error| format!("could not inspect {MEDIA_DEVICE}: {error}"))?;
    if output.status.success() {
        return Ok(!String::from_utf8_lossy(&output.stdout).trim().is_empty());
    }
    if output.status.code() == Some(1) {
        return Ok(false);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    Err(format!("could not inspect {MEDIA_DEVICE}: {stderr}"))
}

#[derive(Clone, Copy)]
enum DesiredState {
    Running,
    Stopped,
}

fn ensure_service(unit: &str, desired: DesiredState) -> Result<()> {
    let active = command_success(SYSTEMCTL, &["is-active", "--quiet", unit])?;
    let (verb, already) = match desired {
        DesiredState::Running => ("start", active),
        DesiredState::Stopped => ("stop", !active),
    };

    if already {
        step(
            format!("{unit} is already {}", state_name(desired)),
            StepState::Skipped,
        );
        return Ok(());
    }

    step(format!("{} {unit}", capitalize(verb)), StepState::Working);
    run_success(SYSTEMCTL, &[verb, unit])?;
    let active_after = command_success(SYSTEMCTL, &["is-active", "--quiet", unit])?;
    let reached_state = matches!(desired, DesiredState::Running) == active_after;
    if !reached_state {
        return Err(format!(
            "{unit} did not become {}; inspect it with: journalctl -u {unit} -n 100 --no-pager",
            state_name(desired)
        ));
    }
    step(
        format!("{unit} is {}", state_name(desired)),
        StepState::Done,
    );
    Ok(())
}

fn print_service_status(label: &str, unit: &str) -> Result<()> {
    let active = command_success(SYSTEMCTL, &["is-active", "--quiet", unit])?;
    let state = if active {
        "running".green().to_string()
    } else {
        "stopped".yellow().to_string()
    };
    println!("  {label:<20} {state}");
    Ok(())
}

fn command_success(program: &str, arguments: &[&str]) -> Result<bool> {
    let output = ProcessCommand::new(program)
        .args(arguments)
        .output()
        .map_err(|error| format!("could not run {program}: {error}"))?;
    Ok(output.status.success())
}

fn run_success(program: &str, arguments: &[&str]) -> Result<Output> {
    let output = ProcessCommand::new(program)
        .args(arguments)
        .output()
        .map_err(|error| format!("could not run {program}: {error}"))?;
    if output.status.success() {
        return Ok(output);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    let detail = if stderr.is_empty() {
        format!("exit status {}", output.status)
    } else {
        stderr
    };
    Err(format!(
        "{program} {} failed: {detail}",
        arguments.join(" ")
    ))
}

fn is_root() -> bool {
    // SAFETY: geteuid has no preconditions and does not dereference pointers.
    unsafe { geteuid() == 0 }
}

unsafe extern "C" {
    fn geteuid() -> u32;
}

fn heading(command: UserCommand) {
    println!("{}  {}", "homelab".bold().cyan(), command.as_str().bold());
}

fn success(message: impl Display) {
    println!("{} {message}", "✓".green().bold());
}

enum StepState {
    Working,
    Done,
    Skipped,
}

fn step(message: impl Display, state: StepState) {
    let marker = match state {
        StepState::Working => "→".cyan().bold().to_string(),
        StepState::Done => "✓".green().bold().to_string(),
        StepState::Skipped => "•".dimmed().to_string(),
    };
    println!("{marker} {message}");
}

fn state_name(state: DesiredState) -> &'static str {
    match state {
        DesiredState::Running => "running",
        DesiredState::Stopped => "stopped",
    }
}

fn capitalize(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_names_are_stable() {
        assert_eq!(UserCommand::Up.as_str(), "up");
        assert_eq!(UserCommand::Down.as_str(), "down");
        assert_eq!(UserCommand::Status.as_str(), "status");
    }

    #[test]
    fn service_state_names_are_human_readable() {
        assert_eq!(state_name(DesiredState::Running), "running");
        assert_eq!(state_name(DesiredState::Stopped), "stopped");
    }

    #[test]
    fn capitalization_keeps_the_rest_of_a_verb() {
        assert_eq!(capitalize("start"), "Start");
        assert_eq!(capitalize(""), "");
    }
}
