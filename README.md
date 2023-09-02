# Profile and Configuration Converter (SuperSlicer/PrusaSlicer to OrcaSlicer)

This is a Perl script that will convert printer, print, and filament profile settings from PrusaSlicer and SuperSlicer INI files to JSON format for use with OrcaSlicer. 

## Table of Contents

- [Features](#features)
- [Limitations and Known Issues](#limitations-and-known-issues)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [A Note About Printer Profiles](#a-note-about-printer-profiles)
- [Command-Line Options](#command-line-options)
- [Contributing](#contributing)
- [License](#license)

## Features

- Converts PrusaSlicer and SuperSlicer printer, print, and filament INI files to OrcaSlicer JSON
- Interactive mode autodetecs your SuperSlicer, PrusaSlicer, and OrcaSlicer installations and asks you what you want to convert
- Advanced mode uses command-line options to specify parameters and can be used to batch-process multiple files without user interaction
- Supports wildcard input patterns to batch process multiple files at once
- Autodetects the type of the input config file and converts it appropriately
- Won't clobber existing output files by default
- Can "merge" new parameters into an existing .json file without modifying the existing data. This is useful when OrcaSlicer is updated to implement additional parameters from SuperSlicer/PrusaSlicer. Existing or previously converted .json files can be updated to include parameters from a SuperSlicer/PrusaSlicer .ini file that aren't already there, without affecting any of the data that is already present.

## Limitations and Known Issues

### General
- At the moment the script only supports FDM/FFF printers, print profiles, and filaments (i.e. any profiles in the "printer," "print," or "filament" subdirectories of your SuperSlicer/PrusaSlicer installation). SLA profiles (such as located in the "sla_material" and "sla_print" subdirectories) are not currently supported.
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
  - File::HomeDir
  - Path::Class
  - String::Escape
  - Term::Choose
  - Term::Form::ReadLine
  - Text::SimpleTable
  - JSON

## Installation

1. Make sure you have Perl installed on your system. You can check the version by running the following command:

    ```
    perl -v
    ```

   - On Windows I use [Strawberry Perl](https://strawberryperl.com/).

2. Install the required Perl modules using CPAN or your system's package manager. For example, if you're using CPAN:

    ```
    cpan Getopt::Long File::Basename File::Glob File::HomeDir Path::Class String::Escape Term::Choose Term::Form::ReadLine Text::SimpleTable JSON
    ```

3. Clone this repository or download the script directly from GitHub.

    ```
    git clone https://github.com/theophile/SuperSlicer_to_Orca_scripts.git
    ```

## Usage

For interactive mode, run the `superslicer_to_orca.pl` script with no command-line options:
```
perl superslicer_to_orca.pl
```
The script will then guide you through the process of selecting which profiles you'd like to convert and will prompt you for any additional information it needs. Afterwards, you'll see a summary screen telling you how everything went.

Optionally, you can use command-line options to tell the script what you'd like to do and what settings to use, in which case it will only prompt you for information you haven't specified. For example:

```
perl superslicer_to_orca.pl --input <PATTERN> --outdir <DIRECTORY> [OPTIONS]
```

On my Windows-based system, the following command will batch convert all my SuperSlicer filament profiles without overwriting any existing files and the newly converted filament profiles will all appear in OrcaSlicer the next time it is started:

```
perl superslicer_to_orca.pl --input C:\Users\%USERNAME%\AppData\Roaming\SuperSlicer\filament\*.ini --outdir C:\Users\%USERNAME%\AppData\Roaming\OrcaSlicer\ --on-existing skip
```

>[!IMPORTANT]
>If an input filename contain spaces, you need to enclose it in quotes or you will get errors.

## A Note About Printer Profiles
What Super/PrusaSlicer calls a "printer," OrcaSlicer calls a "machine." Super/PrusaSlicer stores some printer data (mostly related to network access to the printer) in a separate "physical printer" .ini file located in the `physical_printer` subdirectory. OrcaSlicer stores that network data in the main "machine" .json file, but network access still will not be enabled unless the "machine" is linked (via the `inherits` parameter) to a printer that has been selected and configured from the available system presets in OrcaSlicer.

If you want to have any kind of network access to your converted printer/machine profile, then before using this script, open OrcaSlicer and make sure your target printer appears under the heading `System presets` in your printers list.

Then rerun the script. It will prompt you to select from the detected "physical printer" profiles. Altneratively, you can use the `--physical-printer` flag to specify the location of the .ini file for the physical printer you want to use.

## Command-Line Options

The script accepts the following command-line options:

- `--input <PATTERN>`: Specifies the input PrusaSlicer or SuperSlicer INI file(s). Use this option to bypass the interactive profile selector. You can use wildcards to specify multiple files. (Optional)
- `--outdir <DIRECTORY>`: Specifies the ROOT OrcaSlicer settings directory. (Optional) If this is not specified, the script will default to the typical location, which is:
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
- `--nozzle-size <DECIMAL>`: For print profiles, specifies the diameter (in mm) of the nozzle the print profile is intended to be used with (e.g. --nozzle-size 0.4). If this is not specified, the script will prompt you to enter a nozzle size when converting print profiles. (Optional)
- `--physical-printer <PATTERN>`: Specifies the INI file for the corresponding "physical printer" when converting printer config files. If this option is not used, the script will give you a choice among detected "physical printer" profiles. See [A Note About Printer Profiles](#a-note-about-printer-profiles) for more information. (Optional)
- `--on-existing <CHOICE>`: Forces the behavior when an output file already exists. Valid choices are: `skip` to leave all existing files alone, `overwrite` to overwrite all existing output files, and `merge` to merge new key/value pairs into all existing output files while leaving existing key/value pairs unmodified. (Optional)
- `--force-output`: Forces the script to output the converted JSON files to the output directory specified with `--outdir`. Use this option if you do not want the new files to be placed in your OrcaSlicer settings folder. (Optional)
- `-h`, `--help`: Displays usage information.


## Contributing

Contributions to this project are welcome! If you find any issues or have suggestions for improvements, please open an issue or submit a pull request.

## License

This script is licensed under the GNU General Public License v3.0.


