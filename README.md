# SuperSlicer to OrcaSlicer (Filament and Print Profile Converter)

This is a Perl script that will convert filament and print-type profile settings from PrusaSlicer and SuperSlicer INI files to JSON format for use with OrcaSlicer.

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

When I learned about OrcaSlicer I wanted to check it out but put it off because I didn't want to have to recreate all my profiles. So developed this script to do it for me. 

## Features

- Converts PrusaSlicer and SuperSlicer filament and print INI files to OrcaSlicer JSON
- Supports wildcard input patterns to batch process multiple files at once
- Autodetects whether the input file is a filament profile or a print profile
- Won't clobber existing output files by default

## Limitations

- Currently, .json files created by this script probably will **not** import using OrcaSlicer's `Import-->Import Configs...` function. Instead, you should put the converted .json files directly into OrcaSlicer's config folder and then reload OrcaSlicer. E.g., in Windows, the default location for filament profiles is `C:\Users\%USERNAME%\AppData\Roaming\OrcaSlicer\user\default\filament\`.
- If the source profile contains custom gcode, this script will carry it over verbatim and will **not** attempt to rewrite it to comply with OrcaSlicer's conventions for "placeholders" and the like. Depending on your custom gcode, slicing may fail unless you manually update these fields to use OrcaSlicer placeholders and conventions.
- The script will carry over the `inherits` parameter if it exists in the source profile, but I have not been able to test this because none of my profiles "inherit" from other profiles. If your profiles rely on inheritance, the behavior in OrcaSlicer might be unpredictable.
- SuperSlicer and PrusaSlicer have a lot of settings that aren't supported (yet) in OrcaSlicer, so these are ignored.
- OrcaSlicer has some settings that don't have direct counterparts in PrusaSlicer and SuperSlicer. Where possible, this script will try to come up with reasonable values based on the parameters in the input file, but will otherwise ignore those parameters so OrcaSlicer will use its defaults.
- OrcaSlicer does not allow `filament_max_volumetric_speed` to be zero like PrusaSlicer and SuperSlicer do. So when importing a filament profile that has this parameter set to zero, the script will use a reasonable default value instead.
- OrcaSlicer won't accept a .json file unless it contains a `version` key. At the moment, this script hardcodes a value of "1.6.0.0" for this key. I don't know if this is relevant for general usage.

## Requirements

- Perl 5.10 or later
- The following Perl modules:
  - Getopt::Long
  - File::Basename
  - File::Glob
  - File::Spec
  - String::Escape
  - JSON

## Installation

1. Make sure you have Perl installed on your system. You can check the version by running the following command:

    ```
    perl -v
    ```

   - On Windows I use [Strawberry Perl](https://strawberryperl.com/).

2. Install the required Perl modules using CPAN or your system's package manager. For example, if you're using CPAN:

    ```
    cpan Getopt::Long File::Basename File::Glob File::Spec String::Escape JSON
    ```

3. Clone this repository or download the script directly from GitHub.

    ```
    git clone https://github.com/theophile/SuperSlicer_to_Orca_scripts.git
    ```

## Usage

Run the `superslicer_to_orca.pl` script with the required options:

```
perl superslicer_to_orca.pl --input <PATTERN> --outdir <DIRECTORY> [OPTIONS]
```

For example, on my Windows-based system, the following command will batch convert all my SuperSlicer filament profiles so that they all appear in OrcaSlicer the next time it is started:

```
perl superslicer_to_orca.pl --input C:\Users\%USERNAME%\AppData\Roaming\SuperSlicer\filament\*.ini --outdir C:\Users\%USERNAME%\AppData\Roaming\OrcaSlicer\user\default\filament\
```

## Command-Line Options

The script accepts the following command-line options:

- `--input <PATTERN>`: Specifies the input SuperSlicer INI file(s). You can use wildcards to specify multiple files. (Required)
- `--outdir <DIRECTORY>`: Specifies the output directory where the JSON files will be saved. (Required)
- `--overwrite`: Allows overwriting existing output files. If not specified, the script will exit with a warning if the output file already exists.
- `--nozzle-size`: For print profiles, specifies the diameter (in mm) of the nozzle the print profile is intended to be used with (e.g. --nozzle-size 0.4). This is needed because some parameters must be calculated by reference to the nozzle size, but PrusaSlicer and SuperSlicer print profiles do not store the nozzle size. If this is not specified, the script will use twice the layer height as a proxy for the nozzle width. (Optional)
- `-h`, `--help`: Displays usage information.

## Overwriting Output Files

By default, the script checks if the output file already exists. If so, it will exit with a warning. To force overwriting existing files, use the `--overwrite` option.

## Contributing

Contributions to this project are welcome! If you find any issues or have suggestions for improvements, please open an issue or submit a pull request.

## License

This script is licensed under the GNU General Public License v3.0.


