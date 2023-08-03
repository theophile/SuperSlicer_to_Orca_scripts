# SuperSlicer to OrcaSlicer (Filament Profile Converter)

This is a Perl script that will convert filament profile settings from SuperSlicer INI files to JSON format for use with OrcaSlicer.

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Limitations](#limitations)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Command-Line Options](#command-line-options)
- [Overwriting Output Files](#overwriting-output-files)
- [Contributing](#contributing)
- [License](#license)

## Introduction

Like many SuperSlicer users, I've been considering a switch to OrcaSlicer but have been putting it off because I don't want to have to recreate all my filament profiles. So instead of spending days re-entering filament data, I spent days creating this script to do it for me.

## Features

- Converts SuperSlicer filament INI files to OrcaSlicer JSON
- May convert PrusaSlicer filament profiles as well (untested)
- Supports wildcard input patterns to batch process multiple files at once
- Won't clobber existing output files by default

## Limitations

- The script will carry over the `inherits` parameter from SuperSlicer if it exists, but I have not been able to test this because none of my SuperSlicer filament profiles "inherit" from other profiles. If your profiles rely on inheritance, the behavior in OrcaSlicer might be unpredictable.
- SuperSlicer has a lot of filament-related options that aren't supported (yet) in OrcaSlicer, so these are ignored.
- OrcaSlicer has some filament-related options that don't have direct counterparts in SuperSlicer (e.g. vitrification temperature, recommended nozzle temp range, bed-type-specific print temps, etc.). Where possible, this script will try to come up with reasonable values based on the SuperSlicer configuration, but will otherwise ignore those parameters so OrcaSlicer will use its defaults.
- OrcaSlicer does not allow `filament_max_volumetric_speed` to be zero like SuperSlicer does. So if the input profile has this parameter set to zero, the script will use a reasonable default value instead.
- OrcaSlicer won't accept a filament .json file unless it contains a `version` key. At the moment, this script hardcodes a value of "1.6.0.0" for this key. I don't know if this is relevant for general usage.

## Requirements

- Perl 5.10 or later
- The following Perl modules:
  - Getopt::Long
  - File::Basename
  - File::Glob ':glob'
  - File::Spec
  - String::Escape
  - Config::Tiny
  - JSON

## Installation

1. Make sure you have Perl installed on your system. You can check the version by running the following command:

```
perl -v
```

On Windows I use [Strawberry Perl](https://strawberryperl.com/).

2. Install the required Perl modules using CPAN or your system's package manager. For example, if you're using CPAN:

```
cpan Getopt::Long File::Basename File::Glob File::Spec String::Escape Config::Tiny JSON
```

3. Clone this repository or download the script directly from GitHub.

```
git clone https://github.com/theophile/SuperSlicer_to_Orca_scripts.git
```

## Usage

Run the `superslicer_to_orca-filaments.pl` script with the required options:

```
perl superslicer_to_orca-filaments.pl --input <PATTERN> --outdir <DIRECTORY> [OPTIONS]
```

For example, on my Windows-based system, the following command will batch convert all my SuperSlicer filament profiles so that they all appear in OrcaSlicer the next time it is started:

```
perl superslicer_to_orca-filaments.pl --input C:\Users\%USERNAME%\AppData\Roaming\SuperSlicer\filament\* --outdir "C:\Users\%USERNAME%\AppData\Roaming\OrcaSlicer\user\default\filament\"
```

## Command-Line Options

The script accepts the following command-line options:

- `--input <PATTERN>`: Specifies the input SuperSlicer INI file(s). You can use wildcards to specify multiple files. (Required)
- `--outdir <DIRECTORY>`: Specifies the output directory where the JSON files will be saved. (Required)
- `--overwrite`: Allows overwriting existing output files. If not specified, the script will exit with a warning if the output file already exists.
- `-h`, `--help`: Displays usage information.

## Overwriting Output Files

By default, the script checks if the output file already exists. If so, it will exit with a warning. To force overwriting existing files, use the `--overwrite` option.

## Contributing

Contributions to this project are welcome! If you find any issues or have suggestions for improvements, please open an issue or submit a pull request.

## License

This script is licensed under the GNU General Public License v3.0.


