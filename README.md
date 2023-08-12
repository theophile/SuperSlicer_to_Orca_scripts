# Profile and Configuration Converter (SuperSlicer/PrusaSlicer to OrcaSlicer)

This is a Perl script that will convert printer, print, and filament profile settings from PrusaSlicer and SuperSlicer INI files to JSON format for use with OrcaSlicer.

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Limitations and Known Issues](#limitations-and-known-issues)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [A Note About Printer Profiles](#a-note-about-printer-profiles)
- [Command-Line Options](#command-line-options)
- [Overwriting Output Files](#overwriting-output-files)
- [Contributing](#contributing)
- [License](#license)

## Introduction

When I learned about OrcaSlicer I wanted to check it out but put it off because I didn't want to have to recreate all my profiles. So developed this script to do it for me. 

## Features

- Converts PrusaSlicer and SuperSlicer printer, print, and filament INI files to OrcaSlicer JSON
- Optionally embeds network-configuration data from a specified "physical printer" file
- Supports wildcard input patterns to batch process multiple files at once
- Autodetects the type of the input config file and converts it appropriately
- Won't clobber existing output files by default

## Limitations and Known Issues

### General
- Currently, .json files created by this script probably will **not** import using OrcaSlicer's `Import-->Import Configs...` function. By default, this script puts the converted .json files directly into OrcaSlicer's config folder and they should appear after you reload OrcaSlicer.
- If the source profile contains custom gcode, this script will carry it over verbatim and will **not** attempt to rewrite it to comply with OrcaSlicer's conventions for "placeholders" and the like. Depending on your custom gcode, slicing may fail unless you manually update these fields to use OrcaSlicer placeholders and conventions.
- SuperSlicer and PrusaSlicer have a lot of settings that aren't supported (yet) in OrcaSlicer, so these are ignored.
- OrcaSlicer has some settings that don't have direct counterparts in PrusaSlicer and SuperSlicer. Where possible, this script will try to come up with reasonable values based on the parameters in the input file, but will otherwise ignore those parameters so OrcaSlicer will use its defaults.
- OrcaSlicer won't accept a .json file unless it contains a `version` key. At the moment, this script hardcodes a value of "1.6.0.0" for this key. I don't know if this is relevant for general usage.

### Filament Profiles
- OrcaSlicer does not allow `filament_max_volumetric_speed` to be zero like PrusaSlicer and SuperSlicer do. So when importing a filament profile that has this parameter set to zero, the script will use a reasonable default value instead.
- The script will carry over the `inherits` parameter if it exists in the source profile, but I have not been able to test this because none of my profiles "inherit" from other profiles. If your profiles rely on inheritance, the behavior in OrcaSlicer might be unpredictable.

### Print Profiles
- SuperSlicer and (to a lesser extent) PrusaSlicer have many print parameters that can be entered as either an absolute value or as a percentage of some other value. In the majority of cases, OrcaSlicer requires these parameters to be given as absolute values. Currently this script will handle the necessary conversions and calculations, but be aware that if you are used to using these percent-based values, many setting will no longer "scale" in OrcaSlicer when other settings are adjusted.
- Related to the previous note, there are many parameters that Super/PrusaSlicer allow to be given as a percent of the nozzle diameter, but OrcaSlicer requires an absolute value instead. The problem is that the nozzle diameter is not stored in the print profile, so by default, the script does not know how to calculate the corresponding absolute value. To address this, the user should use the `nozzle-size` command-line option (documented below) when converting print profiles to specify the diameter of the nozzle the profile is intended to be used with (e.g. `--nozzle-size 0.4`). If this command-line option is not used, then the script will assume the nozzle diameter is double the normal layer height specified in the profile. This should work fine in the fairly common scenario where a profile for a 0.4mm nozzle uses a 0.2mm layer height, but will likely produce undesirable results for things like "fine" and "superfine" profiles that use very small layer heights. Therefore, it is recommended to always use the `nozzle-size` command-line option when converting print profiles.
- The script will carry over the `inherits` parameter if it exists in the source profile, but I have not been able to test this because none of my profiles "inherit" from other profiles. If your profiles rely on inheritance, the behavior in OrcaSlicer might be unpredictable.

### Printer Profiles
- See [A Note About Printer Profiles](#a-note-about-printer-profiles).
- Currently OrcaSlicer doesn't support multiple extruders. If you are converting a Super/PrusaSlicer profile for a printer with multiple extruders, the corresponding "machine" in OrcaSlicer will use the settings from the first extruder in the source .ini file.
- Super/PrusaSlicer have separate custom g-code fields for "Tool change G-code" and "Color Change G-code," while OrcaSlicer only has one such field called "Change filament G-code." Currently this script will populate the "Change filament G-code" with the contents of "Tool change G-code" from the source profile. A future version of the script may add a command-line option to use the contents of "Color Change G-code" instead.

## Requirements

- Perl 5.10 or later
- The following Perl modules:
  - Getopt::Long
  - File::Basename
  - File::Glob
  - Path::Class
  - String::Escape
  - Term::Choose
  - JSON

## Installation

1. Make sure you have Perl installed on your system. You can check the version by running the following command:

    ```
    perl -v
    ```

   - On Windows I use [Strawberry Perl](https://strawberryperl.com/).

2. Install the required Perl modules using CPAN or your system's package manager. For example, if you're using CPAN:

    ```
    cpan Getopt::Long File::Basename File::Glob Path::Class String::Escape Term::Choose JSON
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
perl superslicer_to_orca.pl --input C:\Users\%USERNAME%\AppData\Roaming\SuperSlicer\filament\*.ini --outdir C:\Users\%USERNAME%\AppData\Roaming\OrcaSlicer\
```

>[!IMPORTANT]
>If an input filename contain spaces, you need to enclose it in quotes or you will get errors.

## A Note About Printer Profiles
What Super/PrusaSlicer calls a "printer," OrcaSlicer calls a "machine." Super/PrusaSlicer stores some printer data (mostly related to network access to the printer) in a separate "physical printer" .ini file located in the `physical_printer` subdirectory. OrcaSlicer stores that network data in the main "machine" .json file, but network access still will not be enabled unless the "machine" is linked (via the `inherits` parameter) to a printer that has been selected and configured from the available system presets in OrcaSlicer.

If you want to have any kind of network access to your converted printer/machine profile, then before using this script, open OrcaSlicer and make sure your target printer appears under the heading `System presets` in your printers list.

Then, if you want to preserve the network configuration from a particular "physical printer," use the `--physical-printer` flag to specify the location of the .ini file for the physical printer you want to use. Either way, the script will prompt you to select your configured system printer from a list.

## Command-Line Options

The script accepts the following command-line options:

- `--input <PATTERN>`: Specifies the input SuperSlicer INI file(s). You can use wildcards to specify multiple files. (Required)
- `--outdir <DIRECTORY>`: Specifies the ROOT OrcaSlicer settings directory. (Required) The typical locations by OS are:
  - in Windows:
    ```
    C:\Users\%USERNAME%\AppData\Roaming\OrcaSlicer
    ```
  - in MacOS:
    ```
    ~/Library/Application Support/OrcaSlicer
    ```
  - in Linux:
    ```
    ~/.config/OrcaSlicer
    ```
- `--overwrite`: Allows overwriting existing output files. If not specified, the script will exit with a warning if the output file already exists.
- `--nozzle-size <DECIMAL>`: For print profiles, specifies the diameter (in mm) of the nozzle the print profile is intended to be used with (e.g. `--nozzle-size 0.4`). This is needed because some parameters must be calculated by reference to the nozzle size, but PrusaSlicer and SuperSlicer print profiles do not store the nozzle size. If this is not specified, the script will use twice the layer height as a proxy for the nozzle width. (Optional)
- `--physical-printer <PATTERN>`: Specifies the INI file for the corresponding "physical printer" when converting printer config files. If this option is not used, the converted OrcaSlicer "machine" configuration may lack network-configuration data. See [A Note About Printer Profiles](#a-note-about-printer-profiles) for more information. (Optional)
- `--force-output`: Forces the script to output the converted JSON files to the specified output directory. Use this option if you do not want the new files to be placed in your OrcaSlicer settings folder. (Optional)
- `-h`, `--help`: Displays usage information.

## Overwriting Output Files

By default, the script checks if the output file already exists. If so, it will exit with a warning. To force overwriting existing files, use the `--overwrite` option.

## Contributing

Contributions to this project are welcome! If you find any issues or have suggestions for improvements, please open an issue or submit a pull request.

## License

This script is licensed under the GNU General Public License v3.0.


