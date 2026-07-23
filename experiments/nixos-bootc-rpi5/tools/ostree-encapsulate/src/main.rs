use std::collections::BTreeMap;
use std::env;
use std::num::NonZeroU32;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use ostree_ext::container::{self, ImageReference};
use ostree_ext::gio;
use ostree_ext::ostree;

#[derive(Debug, Default)]
struct Args {
    repo: Option<PathBuf>,
    ostree_ref: Option<String>,
    dest: Option<String>,
    labels: BTreeMap<String, String>,
    cmd: Option<String>,
    max_layers: Option<NonZeroU32>,
}

fn parse_args() -> Result<Args> {
    let mut parsed = Args {
        cmd: Some("/sbin/init".to_string()),
        max_layers: NonZeroU32::new(64),
        ..Default::default()
    };

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--repo" => parsed.repo = Some(args.next().context("--repo requires a path")?.into()),
            "--ref" => parsed.ostree_ref = Some(args.next().context("--ref requires a ref or checksum")?),
            "--dest" => parsed.dest = Some(args.next().context("--dest requires an image reference")?),
            "--cmd" => parsed.cmd = Some(args.next().context("--cmd requires a command")?),
            "--label" => {
                let label = args.next().context("--label requires KEY=VALUE")?;
                let (key, value) = label
                    .split_once('=')
                    .with_context(|| format!("invalid label {label:?}; expected KEY=VALUE"))?;
                parsed.labels.insert(key.to_string(), value.to_string());
            }
            "--max-layers" => {
                let value = args.next().context("--max-layers requires a number")?;
                parsed.max_layers = Some(value.parse()?);
            }
            "-h" | "--help" => {
                println!(
                    "usage: ostree-encapsulate --repo REPO --ref REF --dest IMGREF [--label KEY=VALUE] [--cmd CMD]"
                );
                std::process::exit(0);
            }
            other => bail!("unknown argument: {other}"),
        }
    }

    Ok(parsed)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args = parse_args()?;
    let repo_path = args.repo.context("missing --repo")?;
    let ostree_ref = args.ostree_ref.context("missing --ref")?;
    let dest = args.dest.context("missing --dest")?;

    let repo_file = gio::File::for_path(repo_path);
    let repo = ostree::Repo::new(&repo_file);
    repo.open(gio::Cancellable::NONE)
        .context("opening OSTree repo")?;

    let dest: ImageReference = dest.parse().context("parsing destination image reference")?;
    let config = container::Config {
        labels: Some(args.labels),
        cmd: args.cmd.map(|cmd| vec![cmd]),
    };
    let mut opts = container::ExportOpts::default();
    opts.max_layers = args.max_layers;

    let digest = container::encapsulate(&repo, ostree_ref, &config, Some(opts), &dest).await?;
    println!("{digest}");
    Ok(())
}
