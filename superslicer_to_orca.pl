#!/usr/bin/perl
use strict;
use warnings;
no warnings "exiting";

use Getopt::Long;
use File::Basename;
use File::Glob ':glob';
use File::HomeDir;
use Path::Class;
use Path::Tiny;
use String::Escape qw(unbackslash);
use Term::Choose;
use Term::Form::ReadLine;
use Text::SimpleTable;
use JSON;

# Constants
my $ORCA_SLICER_VERSION = '1.6.0.0';

# Subroutine to print usage instructions and exit
sub print_usage_and_exit {
    my $usage = <<'END_USAGE';
Usage: $0 [options]

Options:
  --input <PATTERN>             Specifies the input PrusaSlicer or SuperSlicer
                                INI file(s). Use this option to bypass
                                the interactive profile selector. You can use 
                                wildcards to specify multiple files. You may also
                                pass multiple space-separated arguments to this
                                option to specify multiple filenames. Any file
                                path(s) containing a space must be enclosed in
                                quotes. (Optional)

  --outdir <DIRECTORY>          Specifies the ROOT OrcaSlicer settings directory.
                                (Optional) If this is not specified, the script will
                                default to the typical location, which is:      
                   in Windows:  C:\Users\%USERNAME%\AppData\Roaming\OrcaSlicer
                     in MacOS:  ~/Library/Application Support/OrcaSlicer
                     in Linux:  ~/.config/OrcaSlicer

  --nozzle-size <DECIMAL>       For print profiles, specifies the diameter (in 
                                mm) of the nozzle the print profile is
                                intended to be used with (e.g. --nozzle-size
                                0.4). If this is not specified, the script will
                                prompt you to enter a nozzle size when converting
                                print profiles. (Optional)

  --physical-printer <PATTERN>  Specifies the INI file for the corresponding
                                "physical printer" when converting printer
                                config files. If this option is not used, the
                                script will give you a choice among detected
                                "physical printer" profiles. (Optional)

  --on-existing <CHOICE>        Forces the behavior when an output file already
                                exists. Valid choices are: "skip" to leave all 
                                existing files alone, "overwrite" to overwrite all 
                                existing output files, and "merge" to merge new
                                key/value pairs into all existing output files
                                while leaving existing key/value pairs unmodified.
                                (Optional)

  --force-output                Forces the script to output the converted JSON
                                files to the output directory specified with 
                                '--outdir'. Use this option if you do not want 
                                the new files to be placed in your OrcaSlicer 
                                settings folder. (Optional)

  -h, --help                    Displays this usage information.
END_USAGE

    print $usage;
    exit(1);
}

# Initialize variables to store command-line options
my @input_files;

# Mapping of system directories by OS and ini type
my %system_directories = (
    os => {
        'linux'   => ['.config'],
        'MSWin32' => [ 'AppData', 'Roaming' ],
        'darwin'  => [ 'Library', 'Application Support' ]
    },
    input => {
        'Filament' => 'filament',
        'Print'    => 'print',
        'Printer'  => 'printer'
    },
    output => {
        'filament' => [ 'user', 'default', 'filament' ],
        'print'    => [ 'user', 'default', 'process' ],
        'printer'  => [ 'user', 'default', 'machine' ]
    }
);

my %status = (
    force_out        => 0,
    legacy_overwrite => 0,
    max_temp         => 0,
    interactive_mode => 0,
    slicer_flavor    => undef,
    ini_type         => undef,
    ironing_type     => undef,
    iterations_left  => undef,
    dirs             => {
        output => undef,
        data   =>
          dir( File::HomeDir->my_home, @{ $system_directories{'os'}{$^O} } ),
        slicer => undef,
        temp   => undef,
    },
    to_var => {
        external_perimeters_first => undef,
        infill_first              => undef,
        ironing                   => undef,
    },
    reset => {
        on_existing                   => 0,
        physical_printer              => 0,
        nozzle_size                   => 0,
        inherits                      => 0,
        compatible_printers_condition => 0,
        compatible_prints_condition   => 0
    },
    value => {
        on_existing                   => undef,
        physical_printer              => undef,
        nozzle_size                   => undef,
        inherits                      => undef,
        compatible_printers_condition => undef,
        compatible_prints_condition   => undef
    }
);

# Parse command-line options
GetOptions(
    "input:s{1,}"        => \@input_files,
    "outdir:s"           => \$status{dirs}{output},
    "overwrite"          => \$status{legacy_overwrite},
    "on-existing:s"      => \$status{value}{on_existing},
    "nozzle-size"        => \$status{value}{nozzle_size},
    "physical-printer:s" => \$status{value}{physical_printer},
    "force-output"       => \$status{force_out},
    "h|help"             => sub { print_usage_and_exit(); },
) or die("Error in command-line arguments.\n");

# Make sure --on-existing was given a valid choice
my %on_existing_opts = (
    skip      => 'LEAVE IT ALONE',
    merge     => 'MERGE NEW PARAMETERS',
    overwrite => 'OVERWRITE'
);

if ( defined $status{value}{on_existing} ) {
    if ( exists $on_existing_opts{ $status{value}{on_existing} } ) {
        $status{value}{on_existing} =
          $on_existing_opts{ $status{value}{on_existing} };
    }
    else {
        die(    "Invalid value for --on-existing: $status{value}{on_existing}."
              . " Valid values are 'skip', 'merge', and 'overwrite'.\n" );
    }
}

# Handle deprecated --overwrite option to maintain compatibility
$status{value}{on_existing} = $on_existing_opts{overwrite}
  if $status{legacy_overwrite};

# Set default output directory if not specified
$status{dirs}{output} //= dir( $status{dirs}{data}, 'OrcaSlicer' );

# Subroutine to verify output directory before writing
sub check_output_directory {
    my ($directory) = @_;
    my $die_msg = "\nOutput directory $directory cannot be found.\n";
    unless ($status{force_out}) {
        $die_msg =
            $die_msg
          . "Are you sure that " . $status{dirs}{output} . " is the correct "
          . "ROOT directory of your OrcaSlicer installation?\n(Run this "
          . "script with the -h flag for more info.\n";
    }

    # Check if the output directory exists...
    unless ( -d $directory ) {
        die($die_msg);
    }

    # ...and is writable
    unless ( -w $directory ) {
        die("Output directory $directory is not writable.\n");
    }
}

# Initialize tracking variables and a hash to store translated data
my %new_hash        = ();
my %converted_files = ();

# Helper subroutine to check if a value is a decimal
sub is_decimal {
    my $value = shift;
    return defined $value && $value =~ /^[+-]?\d+(\.\d+)?$/;
}

# Helper subroutine to check if a value is a percentage
sub is_percent {
    my $value = shift;
    return defined $value && $value =~ /^[+-]?\d+(\.\d+)?%$/;
}

# Helper subroutine to remove percent symbol and convert to numeric value
sub remove_percent {
    my $value = shift;
    $value =~ s/%$// if defined $value;
    return $value;
}

# Helper subroutine to convert comma-separated strings to array of values
sub multivalue_to_array {
    my ($input_string) = @_;
    my $delimiter = $input_string =~ /,/ ? ',' : ';';
    return split( /$delimiter/, $input_string );
}

# Subroutine to check if input file is a config bundle
sub is_config_bundle {
    my ($file_path)     = @_;
    my $file            = file($file_path);
    my $bundle_detected = $file->slurp() =~ /\[\w+:[\w\s\+\-]+\]/ ? 1 : 0;
    if ($bundle_detected) {
        $status{dirs}{temp}   = dir( Path::Tiny->tempdir );
        $status{dirs}{slicer} = $status{dirs}{temp};
        $status{dirs}{slicer}->subdir('physical_printer')->mkpath;
    }
    return $bundle_detected;
}

# Subroutine to process a config bundle and split it up into temporary
# individual .ini files for conversion
sub process_config_bundle {
    my $file           = file(@_)->slurp();
    my ($header_line)  = $file =~ /^(# generated[^\n]*)/m;
    my @file_objects;

    # Find line in the form [profile_type:profile_name], and treat everything
    # between that and the next such line as profile_content
    while ( $file =~ /\[([\w\s\+\-]+):([^\]]+)\]\n(.*?)\n(?=\[|$)/sg) {
        my ( $profile_type, $profile_name, $profile_content ) = ( $1, $2, $3 );
        my $physical_printer_profile = ( $profile_type eq "physical_printer" );
        my $temp_file =
          ($physical_printer_profile)
          ? file( $status{dirs}{slicer}->subdir('physical_printer'),
            "$profile_name.ini" )
          : file( $status{dirs}{temp}, "$profile_name.ini" );
        $temp_file->spew("$header_line\n\n$profile_content");
        push @file_objects, $temp_file unless $physical_printer_profile;
    }
    return @file_objects;
}

# Subroutine to translate the feature print sequence settings
sub evaluate_print_order {
    my ( $external_perimeters_first, $infill_first ) = @_;
    if ( !$external_perimeters_first && !$infill_first ) {
        return "inner wall/outer wall/infill";
    }
    if ( $external_perimeters_first && !$infill_first ) {
        return "outer wall/inner wall/infill";
    }
    if ( !$external_perimeters_first && $infill_first ) {
        return "infill/inner wall/outer wall";
    }
    if ( $external_perimeters_first && $infill_first ) {
        return "infill/outer wall/inner wall";
    }

    # Default if we somehow fall through to this point
    return "inner wall/outer wall/infill";
}

# Subroutine to translate the ironing type settings
sub evaluate_ironing_type {
    my ( $ironing, $ironing_type ) = @_;
    if ( defined $ironing && $ironing ) {
        return defined $ironing_type ? $ironing_type : "no ironing";
    }
    return "no ironing";
}

sub percent_to_float {
    my ($subject_value) = @_;
    return $subject_value if ( !is_percent($subject_value) );
    my $new_float = remove_percent($subject_value) / 100;
    return ( $new_float > 2 ) ? '2' : "" . $new_float;
}

# Subroutine to convert percentage value to millimeters
sub percent_to_mm {
    my ( $mm_comparator, $percent_param ) = @_;
    return $percent_param if !is_percent($percent_param);
    return undef          if is_percent($mm_comparator);
    return "" . ( $mm_comparator * ( remove_percent($percent_param) / 100 ) );
}

# Subroutine to convert millimeter values to percentage
sub mm_to_percent {
    my ( $mm_comparator, $mm_param ) = @_;
    return $mm_param if is_percent($mm_param);
    return undef     if is_percent($mm_comparator);
    return ( ( $mm_param / $mm_comparator ) * 100 ) . "%";
}

# Define parameter mappings for translating the source INI settings
# to OrcaSlicer JSON keys
my %parameter_map = (
    'print' => {
        arc_fitting                     => 'enable_arc_fitting',
        bottom_solid_layers             => 'bottom_shell_layers',
        bottom_solid_min_thickness      => 'bottom_shell_thickness',
        bridge_acceleration             => 'bridge_acceleration',
        bridge_angle                    => 'bridge_angle',
        bridge_overlap_min              => 'bridge_density',
        dont_support_bridges            => 'bridge_no_support',
        bridge_speed_internal           => 'internal_bridge_speed',
        brim_ears                       => 'brim_ears',
        brim_ears_detection_length      => 'brim_ears_detection_length',
        brim_ears_max_angle             => 'brim_ears_max_angle',
        brim_separation                 => 'brim_object_gap',
        brim_width                      => 'brim_width',
        brim_speed                      => 'skirt_speed',
        compatible_printers_condition   => 'compatible_printers_condition',
        compatible_printers             => 'compatible_printers',
        default_acceleration            => 'default_acceleration',
        overhangs                       => 'detect_overhang_wall',
        thin_walls                      => 'detect_thin_wall',
        draft_shield                    => 'draft_shield',
        first_layer_size_compensation   => 'elefant_foot_compensation',
        elefant_foot_compensation       => 'elefant_foot_compensation',
        enable_dynamic_overhang_speeds  => 'enable_overhang_speed',
        extra_perimeters_on_overhangs   => 'extra_perimeters_on_overhangs',
        wipe_tower                      => 'enable_prime_tower',
        wipe_speed                      => 'wipe_speed',
        ensure_vertical_shell_thickness => 'ensure_vertical_shell_thickness',
        gap_fill_min_length             => 'filter_out_gap_fill',
        gcode_comments                  => 'gcode_comments',
        gcode_label_objects             => 'gcode_label_objects',
        infill_anchor_max               => 'infill_anchor_max',
        infill_anchor                   => 'infill_anchor',
        fill_angle                      => 'infill_direction',
        infill_overlap                  => 'infill_wall_overlap',
        inherits                        => 'inherits',
        extrusion_width                 => 'line_width',
        extrusion_multiplier            => 'print_flow_ratio',
        first_layer_acceleration        => 'initial_layer_acceleration',
        first_layer_extrusion_width     => 'initial_layer_line_width',
        first_layer_height              => 'initial_layer_print_height',
        interface_shells                => 'interface_shells',
        perimeter_extrusion_width       => 'inner_wall_line_width',
        seam_gap                        => 'seam_gap',
        solid_infill_acceleration       => 'internal_solid_infill_acceleration',
        solid_infill_extrusion_width    => 'internal_solid_infill_line_width',
        ironing_flowrate                => 'ironing_flow',
        ironing_spacing                 => 'ironing_spacing',
        ironing_speed                   => 'ironing_speed',
        layer_height                    => 'layer_height',
        avoid_crossing_perimeters_max_detour  => 'max_travel_detour_distance',
        min_bead_width                        => 'min_bead_width',
        min_feature_size                      => 'min_feature_size',
        solid_infill_below_area               => 'minimum_sparse_infill_area',
        only_one_perimeter_first_layer        => 'only_one_wall_first_layer',
        only_one_perimeter_top                => 'only_one_wall_top',
        ooze_prevention                       => 'ooze_prevention',
        overhangs_reverse                     => 'overhang_reverse',
        overhangs_reverse_threshold           => 'overhang_reverse_threshold',
        perimeter_acceleration                => 'inner_wall_acceleration',
        external_perimeter_acceleration       => 'outer_wall_acceleration',
        external_perimeter_extrusion_width    => 'outer_wall_line_width',
        post_process                          => 'post_process',
        wipe_tower_brim_width                 => 'prime_tower_brim_width',
        wipe_tower_width                      => 'prime_tower_width',
        raft_contact_distance                 => 'raft_contact_distance',
        raft_expansion                        => 'raft_expansion',
        raft_first_layer_density              => 'raft_first_layer_density',
        raft_first_layer_expansion            => 'raft_first_layer_expansion',
        raft_layers                           => 'raft_layers',
        avoid_crossing_perimeters             => 'reduce_crossing_wall',
        only_retract_when_crossing_perimeters => 'reduce_infill_retraction',
        resolution                            => 'resolution',
        seam_position                         => 'seam_position',
        skirt_distance                        => 'skirt_distance',
        skirt_height                          => 'skirt_height',
        skirts                                => 'skirt_loops',
        slice_closing_radius                  => 'slice_closing_radius',
        slicing_mode                          => 'slicing_mode',
        small_perimeter_min_length            => 'small_perimeter_threshold',
        infill_acceleration                   => 'sparse_infill_acceleration',
        fill_density                          => 'sparse_infill_density',
        infill_extrusion_width                => 'sparse_infill_line_width',
        staggered_inner_seams                 => 'staggered_inner_seams',
        standby_temperature_delta             => 'standby_temperature_delta',
        hole_to_polyhole                      => 'hole_to_polyhole',
        hole_to_polyhole_threshold            => 'hole_to_polyhole_threshold',
        hole_to_polyhole_twisted              => 'hole_to_polyhole_twisted',
        support_material                      => 'enable_support',
        support_material_angle                => 'support_angle',
        support_material_enforce_layers       => 'enforce_support_layers',
        support_material_spacing              => 'support_base_pattern_spacing',
        support_material_contact_distance     => 'support_top_z_distance',
        support_material_bottom_contact_distance => 'support_bottom_z_distance',
        support_material_bottom_interface_layers =>
          'support_interface_bottom_layers',
        support_material_interface_contact_loops =>
          'support_interface_loop_pattern',
        support_material_interface_spacing => 'support_interface_spacing',
        support_material_interface_layers  => 'support_interface_top_layers',
        support_material_extrusion_width   => 'support_line_width',
        support_material_buildplate_only   => 'support_on_build_plate_only',
        support_material_threshold         => 'support_threshold_angle',
        thick_bridges                      => 'thick_bridges',
        top_solid_layers                   => 'top_shell_layers',
        top_solid_min_thickness            => 'top_shell_thickness',
        top_solid_infill_acceleration      => 'top_surface_acceleration',
        top_infill_extrusion_width         => 'top_surface_line_width',
        min_width_top_surface              => 'min_width_top_surface',
        travel_acceleration                => 'travel_acceleration',
        travel_speed_z                     => 'travel_speed_z',
        travel_speed                       => 'travel_speed',
        support_tree_angle                 => 'tree_support_branch_angle',
        support_tree_angle_slow            => 'tree_support_angle_slow',
        support_tree_branch_diameter       => 'tree_support_branch_diameter',
        support_tree_branch_diameter_angle => 'tree_support_branch_diameter_angle',
        support_tree_branch_diameter_double_wall => 
          'tree_support_branch_diameter_double_wall',
        support_tree_tip_diameter          => 'tree_support_tip_diameter',
        support_tree_top_rate              => 'tree_support_top_rate',
        wall_distribution_count            => 'wall_distribution_count',
        perimeter_generator                => 'wall_generator',
        perimeters                         => 'wall_loops',
        wall_transition_angle              => 'wall_transition_angle',
        wall_transition_filter_deviation => 'wall_transition_filter_deviation',
        wall_transition_length           => 'wall_transition_length',
        wipe_tower_no_sparse_layers      => 'wipe_tower_no_sparse_layers',
        xy_size_compensation             => 'xy_contour_compensation',
        z_offset                         => 'z_offset',
        xy_inner_size_compensation       => 'xy_hole_compensation',
        support_material_layer_height    => 'independent_support_layer_height',
        fill_pattern                     => 'sparse_infill_pattern',
        output_filename_format           => 'filename_format',
        support_material_pattern         => 'support_base_pattern',
        support_material_interface_pattern => 'support_interface_pattern',
        top_fill_pattern                   => 'top_surface_pattern',
        support_material_xy_spacing        => 'support_object_xy_distance',
        fuzzy_skin_point_dist              => 'fuzzy_skin_point_distance',
        fuzzy_skin_thickness               => 'fuzzy_skin_thickness',
        fuzzy_skin                         => 'fuzzy_skin',
        bottom_fill_pattern                => 'bottom_surface_pattern',
        bridge_flow_ratio                  => 'bridge_flow',
        fill_top_flow_ratio                => 'top_solid_infill_flow_ratio',
        initial_layer_flow_ratio           => 'bottom_solid_infill_flow_ratio',
        infill_every_layers                => 'infill_combination',
        complete_objects                   => 'print_sequence',
        brim_type                          => 'brim_type',
        notes                              => 'notes',
        support_material_style             => 'support_material_style',
        ironing                            => 'ironing',
        ironing_type                       => 'ironing_type',
        ironing_angle                      => 'ironing_angle',
        external_perimeters_first          => 'external_perimeters_first',
        infill_first                       => 'infill_first'
    },

    'filament' => {
        bed_temperature => [
            'hot_plate_temp', 'cool_plate_temp',
            'eng_plate_temp', 'textured_plate_temp'
        ],
        bridge_fan_speed               => 'overhang_fan_speed',
        chamber_temperature            => 'chamber_temperature',
        disable_fan_first_layers       => 'close_fan_the_first_x_layers',
        end_filament_gcode             => 'filament_end_gcode',
        external_perimeter_fan_speed   => 'overhang_fan_threshold',
        extrusion_multiplier           => 'filament_flow_ratio',
        fan_always_on                  => 'reduce_fan_stop_start_freq',
        fan_below_layer_time           => 'fan_cooling_layer_time',
        fan_speedup_time               => 'fan_speedup_time',
        fan_speedup_overhangs          => 'fan_speedup_overhangs',
        fan_kickstart                  => 'fan_kickstart',
        filament_colour                => 'default_filament_colour',
        filament_cost                  => 'filament_cost',
        filament_density               => 'filament_density',
        filament_deretract_speed       => 'filament_deretraction_speed',
        filament_diameter              => 'filament_diameter',
        filament_max_volumetric_speed  => 'filament_max_volumetric_speed',
        filament_notes                 => 'filament_notes',
        filament_retract_before_travel => 'filament_retraction_minimum_travel',
        filament_retract_before_wipe   => 'filament_retract_before_wipe',
        filament_retract_layer_change => 'filament_retract_when_changing_layer',
        filament_retract_length       => 'filament_retraction_length',
        filament_retract_lift         => 'filament_z_hop',
        filament_retract_lift_above   => 'filament_retract_lift_above',
        filament_retract_lift_below   => 'filament_retract_lift_below',
        filament_retract_restart_extra => 'filament_retract_restart_extra',
        filament_retract_speed         => 'filament_retraction_speed',
        filament_shrink                => 'filament_shrink',
        filament_soluble               => 'filament_soluble',
        filament_type                  => 'filament_type',
        filament_wipe                  => 'filament_wipe',
        first_layer_bed_temperature    => [
            'hot_plate_temp_initial_layer',
            'cool_plate_temp_initial_layer',
            'eng_plate_temp_initial_layer',
            'textured_plate_temp_initial_layer'
        ],
        first_layer_temperature   => 'nozzle_temperature_initial_layer',
        full_fan_speed_layer      => 'full_fan_speed_layer',
        inherits                  => 'inherits',
        max_fan_speed             => 'fan_max_speed',
        min_fan_speed             => 'fan_min_speed',
        min_print_speed           => 'slow_down_min_speed',
        slowdown_below_layer_time => 'slow_down_layer_time',
        start_filament_gcode      => 'filament_start_gcode',
        support_material_interface_fan_speed =>
          'support_material_interface_fan_speed',
        temperature                          => 'nozzle_temperature',
        compatible_printers_condition        => 'compatible_printers_condition',
        compatible_printers                  => 'compatible_printers',
        compatible_prints_condition          => 'compatible_prints_condition',
        compatible_prints                    => 'compatible_prints',
        filament_vendor                      => 'filament_vendor',
        filament_minimal_purge_on_wipe_tower =>
          'filament_minimal_purge_on_wipe_tower'
    },

    'printer' => {
        bed_custom_model                   => 'bed_custom_model',
        bed_custom_texture                 => 'bed_custom_texture',
        before_layer_gcode                 => 'before_layer_change_gcode',
        toolchange_gcode                   => 'change_filament_gcode',
        default_filament_profile           => 'default_filament_profile',
        default_print_profile              => 'default_print_profile',
        deretract_speed                    => 'deretraction_speed',
        gcode_flavor                       => 'gcode_flavor',
        inherits                           => 'inherits',
        layer_gcode                        => 'layer_change_gcode',
        feature_gcode                      => 'change_extrusion_role_gcode',
        end_gcode                          => 'machine_end_gcode',
        machine_max_acceleration_e         => 'machine_max_acceleration_e',
        machine_max_acceleration_extruding =>
          'machine_max_acceleration_extruding',
        machine_max_acceleration_retracting =>
          'machine_max_acceleration_retracting',
        machine_max_acceleration_travel  => 'machine_max_acceleration_travel',
        machine_max_acceleration_x       => 'machine_max_acceleration_x',
        machine_max_acceleration_y       => 'machine_max_acceleration_y',
        machine_max_acceleration_z       => 'machine_max_acceleration_z',
        machine_max_feedrate_e           => 'machine_max_speed_e',
        machine_max_feedrate_x           => 'machine_max_speed_x',
        machine_max_feedrate_y           => 'machine_max_speed_y',
        machine_max_feedrate_z           => 'machine_max_speed_z',
        machine_max_jerk_e               => 'machine_max_jerk_e',
        machine_max_jerk_x               => 'machine_max_jerk_x',
        machine_max_jerk_y               => 'machine_max_jerk_y',
        machine_max_jerk_z               => 'machine_max_jerk_z',
        machine_min_extruding_rate       => 'machine_min_extruding_rate',
        machine_min_travel_rate          => 'machine_min_travel_rate',
        pause_print_gcode                => 'machine_pause_gcode',
        start_gcode                      => 'machine_start_gcode',
        max_layer_height                 => 'max_layer_height',
        min_layer_height                 => 'min_layer_height',
        nozzle_diameter                  => 'nozzle_diameter',
        print_host                       => 'print_host',
        printer_notes                    => 'printer_notes',
        bed_shape                        => 'printable_area',
        max_print_height                 => 'printable_height',
        printer_technology               => 'printer_technology',
        printer_variant                  => 'printer_variant',
        retract_before_wipe              => 'retract_before_wipe',
        retract_length_toolchange        => 'retract_length_toolchange',
        retract_restart_extra_toolchange => 'retract_restart_extra_toolchange',
        retract_restart_extra            => 'retract_restart_extra',
        retract_layer_change             => 'retract_when_changing_layer',
        retract_length                   => 'retraction_length',
        retract_lift                     => 'z_hop',
        retract_lift_top                 => 'retract_lift_enforce',
        retract_before_travel            => 'retraction_minimum_travel',
        retract_speed                    => 'retraction_speed',
        silent_mode                      => 'silent_mode',
        single_extruder_multi_material   => 'single_extruder_multi_material',
        thumbnails                       => 'thumbnails',
        thumbnails_format                => 'thumbnails_format',
        template_custom_gcode            => 'template_custom_gcode',
        use_firmware_retraction          => 'use_firmware_retraction',
        use_relative_e_distances         => 'use_relative_e_distances',
        wipe                             => 'wipe'
    },
    'physical_printer' => {
        host_type                    => 1,
        print_host                   => 1,
        printer_technology           => 1,
        printhost_apikey             => 1,
        printhost_authorization_type => 1,
        printhost_cafile             => 1,
        printhost_password           => 1,
        printhost_port               => 1,
        printhost_ssl_ignore_revoke  => 1,
        printhost_user               => 1,
    }
);

# Printer parameters that may be comma-separated lists
my %multivalue_params = (
    max_layer_height                    => 'single',
    min_layer_height                    => 'single',
    deretract_speed                     => 'single',
    default_filament_profile            => 'single',
    machine_max_acceleration_e          => 'array',
    machine_max_acceleration_extruding  => 'array',
    machine_max_acceleration_extruding  => 'array',
    machine_max_acceleration_retracting => 'array',
    machine_max_acceleration_travel     => 'array',
    machine_max_acceleration_x          => 'array',
    machine_max_acceleration_y          => 'array',
    machine_max_acceleration_z          => 'array',
    machine_max_feedrate_e              => 'array',
    machine_max_feedrate_x              => 'array',
    machine_max_feedrate_y              => 'array',
    machine_max_feedrate_z              => 'array',
    machine_max_jerk_e                  => 'array',
    machine_max_jerk_x                  => 'array',
    machine_max_jerk_y                  => 'array',
    machine_max_jerk_z                  => 'array',
    machine_min_extruding_rate          => 'array',
    machine_min_travel_rate             => 'array',
    nozzle_diameter                     => 'single',
    bed_shape                           => 'array',
    retract_before_wipe                 => 'single',
    retract_length_toolchange           => 'single',
    retract_restart_extra_toolchange    => 'single',
    retract_restart_extra               => 'single',
    retract_layer_change                => 'single',
    retract_length                      => 'single',
    retract_lift                        => 'single',
    retract_before_travel               => 'single',
    retract_speed                       => 'single',
    thumbnails                          => 'array',
    extruder_offset                     => 'single',
    retract_lift_above                  => 'single',
    retract_lift_below                  => 'single',
    wipe                                => 'single',
);

# Mapping of SuperSlicer filament types to their Orca Slicer equivalents
my %filament_types = (
    PET   => 'PETG',
    FLEX  => 'TPU',
    NYLON => 'PA'
);

# Define default max volumetric speeds since this can't be zero in Orca Slicer
my %default_MVS = (
    PLA   => '15',
    PET   => '10',
    ABS   => '12',
    ASA   => '12',
    FLEX  => '3.2',
    NYLON => '12',
    PVA   => '12',
    PC    => '12',
    PSU   => '8',
    HIPS  => '8',
    EDGE  => '8',
    NGEN  => '8',
    PP    => '8',
    PEI   => '8',
    PEEK  => '8',
    PEKK  => '8',
    POM   => '8',
    PVDF  => '8',
    SCAFF => '8'
);

my @speed_sequence = (
    'perimeter_speed',                  'external_perimeter_speed',
    'solid_infill_speed',               'infill_speed',
    'small_perimeter_speed',            'top_solid_infill_speed',
    'gap_fill_speed',                   'support_material_speed',
    'support_material_interface_speed', 'bridge_speed',
    'first_layer_speed',                'first_layer_infill_speed'
);

my %speed_params = (
    perimeter_speed                  => 'inner_wall_speed',
    external_perimeter_speed         => 'outer_wall_speed',
    small_perimeter_speed            => 'small_perimeter_speed',
    solid_infill_speed               => 'internal_solid_infill_speed',
    infill_speed                     => 'sparse_infill_speed',
    top_solid_infill_speed           => 'top_surface_speed',
    gap_fill_speed                   => 'gap_infill_speed',
    support_material_speed           => 'support_speed',
    support_material_interface_speed => 'support_interface_speed',
    bridge_speed                     => 'bridge_speed',
    first_layer_speed                => 'initial_layer_speed',
    first_layer_infill_speed         => 'initial_layer_infill_speed'
);

my %seam_positions = (
    cost       => 'nearest',
    random     => 'random',
    allrandom  => 'random',
    aligned    => 'aligned',
    contiguous => 'aligned',
    rear       => 'back',
    nearest    => 'nearest'
);

# Mapping of infill types
my %infill_types = (
    '3dhoneycomb'        => '3dhoneycomb',
    adaptivecubic        => 'adaptivecubic',
    alignedrectilinear   => 'alignedrectilinear',
    archimedeanchords    => 'archimedeanchords',
    concentric           => 'concentric',
    concentricgapfill    => 'concentric',
    cubic                => 'cubic',
    grid                 => 'grid',
    gyroid               => 'gyroid',
    hilbertcurve         => 'hilbertcurve',
    honeycomb            => 'honeycomb',
    lightning            => 'lightning',
    line                 => 'line',
    monotonic            => 'monotonic',
    monotonicgapfill     => 'monotonic',
    monotoniclines       => 'monotonicline',
    octagramspiral       => 'octagramspiral',
    rectilinear          => 'zig-zag',
    rectilineargapfill   => 'zig-zag',
    rectiwithperimeter   => 'zig-zag',
    sawtooth             => 'zig-zag',
    scatteredrectilinear => 'zig-zag',
    smooth               => 'monotonic',
    smoothhilbert        => 'hilbertcurve',
    smoothtriple         => 'triangles',
    stars                => 'tri-hexagon',
    supportcubic         => 'supportcubic',
    triangles            => 'triangles'
);

# Mapping of support types
my %support_styles = (
    grid    => [ 'normal', 'grid' ],
    snug    => [ 'normal', 'snug' ],
    tree    => [ 'tree',   'default' ],
    organic => [ 'tree',   'organic' ]
);

# Recognized support pattern types
my %support_patterns = (
    rectilinear        => 1,
    'rectilinear-grid' => 1,
    honeycomb          => 1,
    lightning          => 1,
    default            => 1,
    hollow             => 1
);

# Recognized support interface pattern types
my %interface_patterns = (
    auto                   => 1,
    rectilinear            => 1,
    concentric             => 1,
    rectilinear_interlaced => 1,
    grid                   => 1
);

# Recognized gcode flavors
my %gcode_flavors = (
    klipper        => 'klipper',
    mach3          => 'reprapfirmware',
    machinekit     => 'reprapfirmware',
    makerware      => 'reprapfirmware',
    marlin         => 'marlin',
    marlin2        => 'marlin2',
    'no-extrusion' => 'reprapfirmware',
    repetier       => 'reprapfirmware',
    reprap         => 'reprapfirmware',
    reprapfirmware => 'reprapfirmware',
    sailfish       => 'reprapfirmware',
    smoothie       => 'reprapfirmware',
    teacup         => 'reprapfirmware',
    sprinter       => 'reprapfirmware',
);

# Recognized printer host types
my %host_types = (
    repetier     => 'repetier',
    prusalink    => 'prusalink',
    prusaconnect => 'prusaconnect',
    octoprint    => 'octoprint',
    moonraker    => 'octoprint',
    mks          => 'mks',
    klipper      => 'octoprint',
    flashair     => 'flashair',
    duet         => 'duet',
    astrobox     => 'astrobox',
);

# Mapping of Z-hop enforcement schemes
my %zhop_enforcement = (
    'All surfaces' => 'All Surfaces',
    'Not on top'   => 'Bottom Only',
    'Only on top'  => 'Top Only',
);

# Mapping of thumbnail formats
my %thumbnail_format = (
    PNG  => 'PNG',
    JPG  => 'JPG',
    QOI  => 'QOI',
    BIQU => 'BTT_TFT',
);

# Subroutine to detect what type of ini file it's being fed
sub detect_ini_type {
    my %source_ini = @_;

    # Iterate over the keys of %parameter_map and count parameter occurrences
    my %type_counts;
    foreach my $type ( keys %parameter_map ) {
        $type_counts{$type} = 0;
        foreach my $parameter ( keys %source_ini ) {
            $type_counts{$type}++ if exists $parameter_map{$type}{$parameter};
        }
    }

    # Return undef Check if all counts are less than 10
    my $invalid_ini = 1;
    foreach my $count ( values %type_counts ) {
        if ( $count >= 10 ) {
            $invalid_ini = 0;
            last;
        }
    }
    return undef if $invalid_ini;

    # Return the key (type) with the highest value (count)
    return ( sort { $type_counts{$b} <=> $type_counts{$a} } keys %type_counts )
      [0];
}

sub convert_params {
    my ( $parameter, $file, %source_ini ) = @_;

    # Get the value of the current parameter from the INI file
    my $new_value = $source_ini{$parameter} // undef;

    # If the SuperSlicer value is 'nil,' skip this parameter and let
    # Orca Slicer use its own default
    return undef if defined $new_value && $new_value eq 'nil';

    # Some printer parameters need to be converted to arrays
    if ( exists $multivalue_params{$parameter} ) {
        $new_value = [ multivalue_to_array($new_value) ];
        $new_value = $new_value->[0]
          if ( $multivalue_params{$parameter} eq 'single' );
    }

    # SuperSlicer has a "default_speed" parameter that PrusaSlicer doesn't,
    # and a lot of percentages are based on that default
    my $default_speed = $source_ini{'default_speed'}
      if ( $status{slicer_flavor} eq 'SuperSlicer' );

    # Check if the parameter maps to multiple keys in the JSON data
    if ( ref( $parameter_map{ $status{ini_type} }{$parameter} ) eq 'ARRAY' ) {

        # If yes, set the same value for each key in the JSON data
        $new_hash{$_} = $new_value
          for @{ $parameter_map{ $status{ini_type} }{$parameter} };
        return;
    }

    # Track state of combination settings
    if ( exists $status{to_var}{$parameter} ) {
        $status{to_var}{$parameter} = $new_value ? 1 : 0;
        return;
    }

    my $unbackslash_gcode = sub {
        $new_value =~ s/^"(.*)"$/$1/;
        $new_value = [ unbackslash($new_value) ];
        return $new_value;
    };

    my $handle_compatible_condition = sub {
        $new_value = ''
          if ( ( defined $status{value}{$parameter} )
            && ( $status{value}{$parameter} eq 'DISCARD' ) );
        return $new_value
          if ( ( $new_value eq '' )
            || ( $status{value}{$parameter} eq 'KEEP' ) );
        my $affected_profile = ( split( '_', $parameter ) )[1];
        chop $affected_profile;
        $status{value}{$parameter} = display_menu(
            "The \e[1m$file\e[0m " . $status{ini_type} . " profile has the "
              . "following \e[1m$parameter\e[0m value:\n\n\t\e[40m\e[0;93m"
              . "$new_value\e[0m\n\nIf you keep this value, this "
              . "$status{ini_type} profile will not be visible in "
              . "OrcaSlicer unless you have selected a $affected_profile that "
              . "satisfies all the conditions specified above. If you discard "
              . "this value, this $status{ini_type} profile will be "
              . "visible regardless of which $affected_profile you have "
              . "selected.\n\nDo you want to KEEP this value or DISCARD it?\n\n",
            1,
            ( 'KEEP', 'DISCARD' )
        );
        ask_yes_to_all( $parameter, $file );
    };

    # Dispatch table for handling special cases
    my %special_cases = (

        # The custom gcode blocks need to be unquoted and unbackslashed
        # before JSON encoding
        'start_filament_gcode'     => $unbackslash_gcode,
        'end_filament_gcode'       => $unbackslash_gcode,
        'post_process'             => $unbackslash_gcode,
        'before_layer_gcode'       => $unbackslash_gcode,
        'toolchange_gcode'         => $unbackslash_gcode,
        'layer_gcode'              => $unbackslash_gcode,
        'feature_gcode'            => $unbackslash_gcode,
        'end_gcode'                => $unbackslash_gcode,
        'pause_print_gcode'        => $unbackslash_gcode,
        'start_gcode'              => $unbackslash_gcode,
        'template_custom_gcode'    => $unbackslash_gcode,
        'notes'                    => $unbackslash_gcode,
        'filament_notes'           => $unbackslash_gcode,
        'printer_notes'            => $unbackslash_gcode,

        # Translate filament type to a specific value if it exists in
        # the mapping, otherwise keep the original value
        'filament_type' => sub {
            return $filament_types{$new_value} // $new_value;
        },

        # Max volumetric speed can't be zero so use a reasonable default
        # if necessary
        'filament_max_volumetric_speed' => sub {
            return "" . ( $new_value > 0 )
              ? $new_value
              : $default_MVS{ $source_ini{'filament_type'} };
        },

        'draft_shield' => sub {
            return
                $new_value eq 'disabled' ? "0"
              : $new_value eq 'enabled'  ? "1"
              :                            $new_value;
        },

        # 'external_perimeter_fan_speed' in SS is the closest equivalent to
        # 'overhang_fan_threshold' in Orca, so convert to percentage
        'external_perimeter_fan_speed' => sub {
            return ( $new_value < 0 ) ? '0%' : "$new_value%";
        },

        # Catch ironing_type and update tracking variable
        'ironing_type' => sub { $status{ironing_type} = $new_value },

        'default_filament_profile' => sub {
            my $new_array = [ multivalue_to_array($new_value) ];
            $new_value = $new_array->[0];
            $unbackslash_gcode->();
            return $new_value->[0];
        },
        
        'retract_lift_top' => sub {
            my $new_array = [ multivalue_to_array($new_value) ];
            $new_value = $new_array->[0];
            $unbackslash_gcode->();
            return $zhop_enforcement{$new_value->[0]};
        },

        # Give user a choice about "compatible" condition strings
        'compatible_printers_condition' => $handle_compatible_condition,
        'compatible_prints_condition'   => $handle_compatible_condition,

        # Some values may need to be converted from percent of nozzle width to
        # absolute value in mm
        'max_layer_height' => sub {
            return percent_to_mm( $status{value}{nozzle_size},
                $new_value );
        },
        'min_layer_height' => sub {
            return percent_to_mm( $status{value}{nozzle_size},
                $new_value );
        },
        'fuzzy_skin_point_dist' => sub {
            return percent_to_mm( $status{value}{nozzle_size},
                $new_value );
        },
        'fuzzy_skin_thickness' => sub {
            return percent_to_mm( $status{value}{nozzle_size},
                $new_value );
        },
        'small_perimeter_min_length' => sub {
            return percent_to_mm( $status{value}{nozzle_size},
                $new_value );
        },

        # Convert percents to float, capping at 2 as OrcaSlicer expects
        'bridge_flow_ratio'   => sub { return percent_to_float($new_value) },
        'fill_top_flow_ratio' => sub { return percent_to_float($new_value) },

        'wall_transition_length' => sub {
            return mm_to_percent( $status{value}{nozzle_size},
                $new_value );
        },

        # Option "0" means "same as top," so set that manually
        'support_material_bottom_contact_distance' => sub {
            return ( $new_value eq '0' )
              ? $source_ini{'support_material_contact_distance'}
              : $new_value;
        },

        # OrcaSlicer consolidates three support-material options to two
        'support_material_style' => sub {
            my ( $support_type, $support_style ) =
              @{ $support_styles{$new_value} };
            my $genstyle =
              ( !!$source_ini{'support_material_auto'} )
              ? 'auto'
              : 'manual';
            $new_hash{'support_type'}  = "${support_type}(${genstyle})";
            $new_hash{'support_style'} = $support_style;
            next;
        },

        # Translate infill types
        'fill_pattern'        => sub { return $infill_types{$new_value} },
        'top_fill_pattern'    => sub { return $infill_types{$new_value} },
        'bottom_fill_pattern' => sub { return $infill_types{$new_value} },

        'gcode_flavor' => sub { return $gcode_flavors{$new_value} // undef; },

        'host_type' => sub { return $host_types{$new_value} },

        'thumbnails_format' => sub { return $thumbnail_format{$new_value} },

        # Set support pattern to default if we can't match the original pattern
        'support_material_pattern' => sub {
            return ( exists $support_patterns{$new_value} )
              ? $new_value
              : 'default';
        },

        # Set support interface pattern to auto if we can't match it
        'support_material_interface_pattern' => sub {
            return ( exists $interface_patterns{$new_value} )
              ? $new_value
              : 'auto';
        },

        # Translate seam position
        'seam_position' => sub { return $seam_positions{$new_value} },

        # Assume that if support material layer height was specified, we want
        # independent support layer heights (true/false in OrcaSlicer)
        'support_material_layer_height' => sub {
            return ( $new_value > 0 ) ? '1' : '0';
        },

        # OrcaSlicer uses angle brackets instead of square here
        'output_filename_format' => sub {
            return $new_value =~ s/\[|\]/ { $& eq '[' ? '{' : '}' } /egr;
        },

        # If this is a percent, try to calculate based on external extrusion
        # width. If that's also a percent, use nozzle size.
        'support_material_xy_spacing' => sub {
            $new_value =
              percent_to_mm( $source_ini{'external_perimeter_extrusion_width'},
                $new_value );
            if ( !defined ) {
                $new_value = percent_to_mm( $status{value}{nozzle_size},
                    $new_value );
            }
            return defined $new_value ? "" . $new_value : undef;
        },

        # Interpret empty extrusion_width as zero
        'extrusion_width' =>
          sub { return ( $new_value eq "" ) ? '0' : $new_value },

        # Convert numerical input to boolean
        'infill_every_layers' => sub { return ( $new_value > 0 ) ? '1' : '0' },

        # Super/PrusaSlicer have this as boolean where OrcaSlicer offers
        # choices in a dropdown
        'complete_objects' =>
          sub { return ( !!$new_value ) ? 'by object' : 'by layer' },

        'external_perimeter_speed' => sub {
            return percent_to_mm( $source_ini{'perimeter_speed'}, $new_value );
        },

        'first_layer_speed' => sub {
            return percent_to_mm( $source_ini{'perimeter_speed'}, $new_value );
        },

        'top_solid_infill_speed' => sub {
            return percent_to_mm( $new_hash{'internal_solid_infill_speed'},
                $new_value );
        },

        'support_material_interface_speed' => sub {
            return percent_to_mm( $source_ini{'support_material_speed'},
                $new_value );
        },

        'first_layer_infill_speed' => sub {
            return percent_to_mm( $source_ini{'infill_speed'},
                ( $status{slicer_flavor} eq 'PrusaSlicer' )
                ? $source_ini{'first_layer_speed'}
                : $new_value );
        },

        # PrusaSlicer calculates solid infill speed as a percentage of sparse
        'solid_infill_speed' => sub {
            return percent_to_mm(
                ( $status{slicer_flavor} eq 'PrusaSlicer' )
                ? $source_ini{'infill_speed'}
                : $default_speed,
                $new_value
            );
        },

        'perimeter_speed' => sub {
            return ( $status{slicer_flavor} eq 'SuperSlicer' )
              ? percent_to_mm( $default_speed, $new_value )
              : $new_value;
        },

        'support_material_speed' => sub {
            return ( $status{slicer_flavor} eq 'SuperSlicer' )
              ? percent_to_mm( $default_speed, $new_value )
              : $new_value;
        },

        'bridge_speed' => sub {
            return ( $status{slicer_flavor} eq 'SuperSlicer' )
              ? percent_to_mm( $default_speed, $new_value )
              : $new_value;
        },

        'infill_speed' => sub {
            return ( $status{slicer_flavor} eq 'SuperSlicer' )
              ? percent_to_mm( $new_hash{'internal_solid_infill_speed'},
                $new_value )
              : $new_value;
        },

        'small_perimeter_speed' => sub {
            return ( $status{slicer_flavor} eq 'SuperSlicer' )
              ? percent_to_mm( $new_hash{'sparse_infill_speed'}, $new_value )
              : $new_value;
        },

        'gap_fill_speed' => sub {
            return ( $status{slicer_flavor} eq 'SuperSlicer' )
              ? percent_to_mm( $new_hash{'sparse_infill_speed'}, $new_value )
              : $new_value;
        },
    );

    if ( exists $special_cases{$parameter} ) {
        $new_value = $special_cases{$parameter}->();
    }

    return $new_value;
}

sub calculate_print_params {
    my %source_ini = @_;

    # Translate and convert speed settings because Super/PrusaSlicer allow
    # percent-based speeds where OrcaSlicer requires absolute values
    foreach my $parameter (@speed_sequence) {

        next if ( !exists $source_ini{$parameter} );

        my $new_value = convert_params( $parameter, undef, %source_ini );

        # Limit mm/s values to one decimal place so OrcaSlicer doesn't choke
        if ( is_decimal($new_value) ) {
            $new_value = sprintf( "%.1f", $new_value );
        }
        $new_value =~ s/\.?0+$//;    # Chop trailing zeroes
        $new_hash{ $speed_params{$parameter} } = "" . $new_value;
    }

    # Translate the Dynamic Overhangs thresholds
    my $enable_dynamic_overhang_speeds =
      !!$source_ini{'enable_dynamic_overhang_speeds'};
    $new_hash{'enable_overhang_speed'} =
      $enable_dynamic_overhang_speeds ? '1' : '0';
    if ($enable_dynamic_overhang_speeds) {
        my @speeds =
          split( ',', $source_ini{'dynamic_overhang_speeds'} );
        my @overhang_speed_keys = (
            'overhang_1_4_speed', 'overhang_2_4_speed',
            'overhang_3_4_speed', 'overhang_4_4_speed'
        );
        @new_hash{@overhang_speed_keys} = @speeds[ 3, 2, 1, 0 ];
    }

    # Set the wall infill order string based on the tracked sequence options
    $new_hash{'wall_infill_order'} =
      evaluate_print_order( $status{to_var}{external_perimeters_first},
        $status{to_var}{infill_first} );

    # Set the ironing type based on the tracked options
    $new_hash{'ironing_type'} =
      evaluate_ironing_type( $status{to_var}{ironing}, $status{ironing_type} );

    return %new_hash;
}

# Subroutine to parse physical printer config if specified
sub handle_physical_printer {
    my ($input_file) = @_;
    my %printer_hash = ();
    my $file         = basename( $input_file->basename, ".ini" );

    if ( !defined $status{value}{physical_printer} ) {
        if ( -d $status{dirs}{slicer}->subdir('physical_printer') ) {
            my $item_dir   = $status{dirs}{slicer}->subdir('physical_printer');
            my @items      = $item_dir->children(qr/\.ini$/);
            my @item_names = map { basename( $_, '.ini' ) } @items;
            push @item_names, '<NONE>';
            $status{value}{physical_printer} = display_menu(
                'In SuperSlicer and some versions of PrusaSlicer, most network-'
                  . 'configuration settings are stored in a separate "physical '
                  . 'printer" .ini file. Choose one of the detected physical '
                  . 'printers below if you want to include its network settings '
                  . "in $file\n\n",
                1, @item_names
            );

            unless ( $status{value}{physical_printer} eq '<NONE>' ) {
                $status{value}{physical_printer} =
                  file( $item_dir, $status{value}{physical_printer} . '.ini' );
            }
            
            ask_yes_to_all( 'physical_printer', $file );

        }
        else {
            $status{value}{physical_printer} = $input_file;
        }
    }

    return if $status{value}{physical_printer} eq '<NONE>';

    my %printer_ini = ini_reader( file($status{value}{physical_printer}) )
      or die "Error reading " . $status{value}{physical_printer} . ": $!";
    foreach my $parameter ( keys %printer_ini ) {

        # Ignore parameters that Orca Slicer doesn't support
        next unless exists $parameter_map{'physical_printer'}{$parameter};

        my $new_value = convert_params( $parameter, $file, %printer_ini );

        next if $new_value eq "";

        # Set the translated value in the JSON data
        $printer_hash{$parameter} = $new_value // "";
    }
    return %printer_hash;
}

# Subroutine to link converted "machine" profile to system printer
sub link_system_printer {
    if (defined $status{value}{inherits} ) {
        return ( 'inherits' => $status{value}{inherits} )
    }
    my ($input_file) = @_;
    my $sys_dir = dir( $status{dirs}{output}, 'system' );
    my %unique_names;
    if (-d $sys_dir) {
        foreach my $file ($sys_dir->children) {
            next unless -f $file && $file->basename =~ /\.json$/;
            my $decoded_data = decode_json($file->slurp);
            if (exists $decoded_data->{machine_list}) {
                for my $machine (@{$decoded_data->{machine_list}}) {
                    my $name = $machine->{name};
                    $unique_names{$name} = 1 if $name !~ /common/i;
                }
            }
        }
    }
    my @sorted_names = sort keys %unique_names;
    push @sorted_names, '<NONE>';
    $status{value}{inherits} = display_menu(
        'In OrcaSlicer, a "machine" profile must be associated with a '
          . 'printer selected and configured from the available system presets. '
          . 'Below is a list of the configured printers that '
          . 'have been detected in your OrcaSlicer installation.' . "\n\n"
          . 'If you do not see the printer you wish to associate with this '
          . "profile, choose \e[1;31m<QUIT>\e[0m to exit this script, then configure "
          . 'your desired printer in OrcaSlicer and run this script again. '
          . "Alternatively, you may select \e[1m<NONE>\e[0m to proceed without "
          . 'associating this "machine" profile with a configured printer, but '
          . "network configuration and g-code upload will not be available.\n\n"
          . 'Please choose an OrcaSlicer printer to associate with '
          . "\e[1m$input_file\e[0m:\n",
        1, @sorted_names
    );
    ask_yes_to_all('inherits', $input_file);
    $status{value}{inherits} = '' if ($status{value}{inherits} eq '<NONE>');

    return ( 'inherits' => $status{value}{inherits} );
}

# Subroutine to parse an .ini file and return a hash with all key/value pairs
sub ini_reader {
    my ($file) = @_;
    my %config;
    foreach my $line ( $file->slurp() ) {

        # Detect which slicer we're importing from
        $status{slicer_flavor} = $1
          if ( $line =~ /^#\s*generated\s+by\s+(\S+)/i );

        next if $line =~ /^\s*(?:#|$)/;    # Skip empty and comment lines
        my ( $key, $value ) =
          map { s/^\s+|\s+$//gr } split /\s* = \s*/, $line, 2;
        $config{$key} = $value;
    }
    return %config;
}

# Subroutine to parse a .json file and return a hash with all key/value pairs
sub merge_new_parameters {
    my ($existing_file) = @_;
    my $existing_json = decode_json( $existing_file->slurp );
    foreach my $key ( keys %$existing_json ) {
        $new_hash{$key} = $existing_json->{$key};
    }
}

# Subroutine to reset the tracked data to prepare for the next input file
sub reset_loop {
    %new_hash = ();
    $status{max_temp} = 0;
    $status{ini_type}                          //= undef;
    $status{to_var}{external_perimeters_first} //= undef;
    $status{to_var}{infill_first}              //= undef;
    $status{to_var}{ironing}                   //= undef;
    $status{ironing_type}                      //= undef;
    for my $param ( keys %{ $status{reset} } ) {
        if ( $status{reset}{$param} ) {
            $status{value}{$param} = undef;
            $status{reset}{$param} = 0;
        }
    }
    unless ( $status{'interactive_mode'} ) {
        $status{ini_type} = undef;
    }
}

sub log_file_status {
    my ( $input_file, $output_file, $slicer_flavor, $success, $error ) = @_;
    my %completed_file = (
        input_file    => $input_file->basename,
        input_dir     => $input_file->dir,
        slicer_flavor => $slicer_flavor,
        output_file   => ( defined $output_file ) ? $output_file->basename : "",
        output_dir    => ( defined $output_file ) ? $output_file->dir      : "",
        success       => $success,
        error         => $error // ""
    );

    if ( $status{ini_type} eq 'printer' ) {
        $completed_file{'physical_printer_file'} =
          ( -f $status{value}{physical_printer} )
          ? $status{value}{physical_printer}->basename
          : "None";
        $completed_file{'physical_printer_dir'} =
          ( -f $status{value}{physical_printer} )
          ? $status{value}{physical_printer}->dir
          : "";
    }
    push @{ $converted_files{ ucfirst( $status{ini_type} ) } },
      \%completed_file;
    reset_loop();
}

sub display_menu {
    my ( $prompt, $is_single_option, @options ) = @_;
    my $quit         = "\e[1;31m<QUIT>\e[0m";
    my %menu_options = (
        prompt           => $prompt,
        clear_screen     => 1,
        layout           => 2,
        codepage_mapping => 1,
        color            => 2
    );

    if ($is_single_option) {
        push @options, $quit;
        my $choice = Term::Choose::choose( \@options, \%menu_options );
        exit_with_conversion_summary() if $choice eq $quit;
        return $choice;
    }
    else {
        $menu_options{'layout'}              = 1;
        $menu_options{'include_highlighted'} = 1;
        my @menu_items = ( '<ALL>', @options, $quit );
        my @choices    = Term::Choose::choose( \@menu_items, \%menu_options );
        exit_with_conversion_summary()
          if grep { $_ eq $quit } @choices;
        return @options if grep { $_ eq '<ALL>' } @choices;
        return @choices;
    }
}

sub ask_yes_to_all {
    my ( $param, $file ) = @_;
    return if !$status{iterations_left};
    my $choice = display_menu(
        "You have chosen \e[1m$status{value}{$param}\e[0m. Would you like to "
          . "apply this choice to ALL remaining profiles you are importing in "
          . "this session? Or just to \e[1m$file\e[0m?\n",
        1,
        ( 'ALL REMAINING PROFILES', "JUST $file" )
    );
    $status{reset}{$param} = 1
      if ( $choice ne 'ALL REMAINING PROFILES' );
}

###################
#                 #
#    MAIN LOOP    #
#                 #
###################

# Determine what to convert if not specified
if ( !@input_files ) {
    $status{'interactive_mode'} = 1;
    my @source_slicers = map { $_->basename }
      grep { /PrusaSlicer|SuperSlicer/ } $status{dirs}{data}->children;

    if ( !@source_slicers ) {
        die(    "No PrusaSlicer or SuperSlicer directories detected in "
              . "$status{dirs}{data}.\n\n Please verify the location of "
              . 'the files you wish to convert and specify them with the '
              . "--input option if necessary." );
    }

    my $slicer_choice =
      display_menu( "Which slicer do you want to import from?\n",
        1, @source_slicers );

    $status{dirs}{slicer} = $status{dirs}{data}->subdir($slicer_choice);

    my @config_types = map { ucfirst($_) }
      grep { -d dir( $status{dirs}{slicer}->subdir($_) ) }
      qw(filament print printer);
    my $config_choice =
      display_menu( "What kind of profile would you like to import?\n",
        1, @config_types );

    $status{ini_type} = lc($config_choice);
    my $item_dir = $status{dirs}{slicer}->subdir( lc($config_choice) );

    my @items      = $item_dir->children(qr/\.ini$/);
    my @item_names = map { basename( $_, '.ini' ) } @items;
    my @choices    = display_menu(
        "Which profile(s) would you like to import?\n\n"
          . "(Toggle multiple selections with <SPACE>. Press <ENTER> when finished.)\n",
        0, @item_names
    );
    push @input_files, map { file( $item_dir, $_ . '.ini' ) } @choices;
}

# Expand wildcards and process each input file
my @expanded_input_files;
foreach my $pattern (@input_files) {
    my @iterator =
      ( -d $pattern ) ? dir($pattern)->children : bsd_glob($pattern);
    foreach my $file (@iterator) {
        next unless -f $file && file($file)->basename =~ qr/\.ini$/;
        push @expanded_input_files,
          is_config_bundle($file) ? process_config_bundle($file) : file($file);
    }
}

my $total_input_files = scalar @expanded_input_files;

foreach my $index ( 0 .. $#expanded_input_files ) {
    my $iteration = $index + 1;
    $status{iterations_left} = $total_input_files - $iteration;

    # Extract filename and directory from the input file
    my $input_file = $expanded_input_files[$index];
    my $dir        = $input_file->dir;
    my $file       = basename( $input_file->basename, ".ini" );

    # Read the input INI file and set source slicer flavor
    my %source_ini = ini_reader($input_file);

    if ( !defined $status{slicer_flavor} ) {
        log_file_status( $input_file, undef, "Unknown", "NO",
            "Unsupported slicer" );
        next;
    }

    $status{ini_type} = $status{ini_type} // detect_ini_type(%source_ini);
    if ( !defined $status{ini_type} ) {
        $status{ini_type} = "unsupported";
        log_file_status( $input_file, undef, $status{slicer_flavor}, "NO",
            "Unsupported file" );
        next;
    }

    # Make sure output directory is correct
    my $subdir =
      $status{force_out}
      ? dir( $status{dirs}{output} )
      : dir( $status{dirs}{output},
        @{ $system_directories{'output'}{ $status{ini_type} } } );

    check_output_directory($subdir);

    my $output_file = file( $subdir, "$file.json" );

    # If nozzle size isn't specified or detected, use 2x layer size as a proxy
    if ( exists $source_ini{'nozzle_diameter'} ) {
        my @nozzle_diameters =
          multivalue_to_array( $source_ini{'nozzle_diameter'} );
        $status{value}{nozzle_size} = $nozzle_diameters[0];
    }
    if (   ( !defined $status{value}{nozzle_size} )
        && ( $status{ini_type} eq 'print' ) )
    {
        $status{value}{nozzle_size} = Term::Form::ReadLine->new->readline(
            'Nozzle size: ',
            {
                color            => 1,
                codepage_mapping => 1,
                info => 'Enter the nozzle size (in mm) of the nozzle '
                  . "intended to be used with the \e[1m$file\e[0m profile "
                  . "(e.g. 0.4). Press <ENTER> when done.\n",
                default => ''
            }
        );
        $status{value}{nozzle_size} =~ s/[^\d.]//g
          if $status{value}{nozzle_size};
        ask_yes_to_all( 'nozzle_size', $file );

        if ( !defined $status{value}{nozzle_size} ) {
            my $layer_height = $source_ini{'layer_height'};
            if ( !$layer_height ) {
                log_file_status( $input_file, $output_file,
                    $status{slicer_flavor}, "NO", "Invalid layer height" );
                next;
            }
            $status{value}{nozzle_size} = 2 * $source_ini{'layer_height'};
        }
    }

    # Loop through each parameter in the INI file
    foreach my $parameter ( keys %source_ini ) {

        # Ignore parameters that Orca Slicer doesn't support
        next unless exists $parameter_map{ $status{ini_type} }{$parameter};

        my $new_value = convert_params( $parameter, $file, %source_ini );

        # Move on if we didn't get a usable value. Otherwise, set the translated
        # value in the JSON data
        next unless defined $new_value;
        $new_hash{ $parameter_map{ $status{ini_type} }{$parameter} } =
          $new_value;

        # Track the maximum commanded nozzle temperature
        $status{max_temp} = $new_value
          if $parameter =~ /^(first_layer_temperature|temperature)$/
          && $new_value > $status{max_temp};
    }

    # Add additional general metadata to the JSON data
    %new_hash = (
        %new_hash,
        $status{ini_type} . "_settings_id" => $file,
        name                               => $file,
        from                               => 'User',
        is_custom_defined                  => '1',
        version                            => $ORCA_SLICER_VERSION
    );

    # Add additional profile-specific metadata to the JSON data
    if ( $status{ini_type} eq 'filament' ) {
        %new_hash = (
            %new_hash,
            nozzle_temperature_range_low  => '0',
            nozzle_temperature_range_high => "" . $status{max_temp},
            slow_down_for_layer_cooling   => (
                ( $source_ini{'slowdown_below_layer_time'} > 0 )
                ? '1'
                : '0'
            )
        );
    }
    elsif ( $status{ini_type} eq 'print' ) {
        %new_hash = ( calculate_print_params(%source_ini) );
    }
    elsif ( $status{ini_type} eq 'printer' ) {
        my %inherits          = link_system_printer($file);
        my %phys_printer_data = handle_physical_printer($input_file);
        %new_hash = ( %new_hash, %phys_printer_data, %inherits );
    }

    # Check if the output file already exists and handle overwrite option
    if ( -e $output_file ) {
        if ( !defined $status{value}{on_existing} ) {
            my @menu_items = (
                $on_existing_opts{skip},
                $on_existing_opts{overwrite},
                $on_existing_opts{merge}
            );
            my $output_basename =
              "\e[40m\e[0;93m" . $output_file->basename . "\e[0m";
            $status{value}{on_existing} = display_menu(
                "Output file '$output_file' already exists!\n\n"
                  . "If you \e[1m$on_existing_opts{skip}\e[0m, the existing "
                  . "file will not be modified and this profile will not be "
                  . "converted.\n\nIf you \e[1m$on_existing_opts{overwrite}"
                  . "\e[0m it, $output_basename will be replaced with the "
                  . "contents of this converted profile.\n\nIf you \e[1m"
                  . "$on_existing_opts{merge}\e[0m, $output_basename will be "
                  . "amended to add any new key/value pairs from the source .ini "
                  . "that are not already present. Pre-existing key/value pairs "
                  . "in $output_basename will not be altered.\n\n"
                  . "What would you like to do?\n",
                1, @menu_items
            );
            ask_yes_to_all( 'on_existing', $file );
        }

        if ( $status{value}{on_existing} eq $on_existing_opts{skip} ) {
            log_file_status( $input_file, $output_file,
                $status{slicer_flavor}, "NO", "Target file exists" );
            next;
        }
        elsif ( $status{value}{on_existing} eq $on_existing_opts{merge} ) {
            merge_new_parameters($output_file);
        }

    }

    # Write the JSON data to the output file
    $output_file->spew( JSON->new->pretty->canonical->encode( \%new_hash ) );

    log_file_status(
        $input_file,
        $output_file,
        $status{slicer_flavor},
        (
                 ( defined $status{value}{on_existing} )
              && ( $status{value}{on_existing} eq $on_existing_opts{merge} )
          )
        ? "MERGED"
        : "YES",
        undef
    );
}

exit_with_conversion_summary();

sub exit_with_conversion_summary {
    exit if (!keys %converted_files);
    my ($input_dir, $output_dir);
    my $indent = 0;
    my $outstring = "CONVERSION SUMMARY";
    my %tables;
    foreach my $file_type ( keys %converted_files ) {

        my $max_table_width = 100;
        my @column_order    = (
            'slicer_col',       'item_name_col',
            'phys_printer_col', 'converted_col',
            'error_col'
        );
        our %columns = (
            slicer_col => {
                name    => "Source File\nGenerated By",
                width   => 12,
                content => []
            },
            item_name_col => {
                name    => "$file_type Profile Name",
                width   => 40,
                content => []
            },
            phys_printer_col => {
                name    => "Imported Physical\nPrinter Data",
                width   => 0,
                content => []
            },
            converted_col => {
                name    => "Converted?",
                width   => 10,
                content => []
            },
            error_col => {
                name    => "Error",
                width   => 0,
                content => []
            }
        );

        sub get_table_width {
            my $total_columns = scalar grep { $_->{width} > 0 } values %columns;
            my $column_margins          = $total_columns * 2;
            my $table_borders           = 2;
            my $borders_between_columns = $total_columns - 1;
            my $additional_width =
              $column_margins + $table_borders + $borders_between_columns;
            my $total_table_width = 0;
            foreach my $col_info ( values %columns ) {
                $total_table_width += $col_info->{width};
            }
            $total_table_width += $additional_width;
            return $total_table_width;
        }

        $input_dir = $converted_files{$file_type}[0]{input_dir};
        foreach my $index ( 0 .. $#{ $converted_files{$file_type} } ) {
            $output_dir = $converted_files{$file_type}[$index]{output_dir};
            last if $output_dir ne "";
        }

        my $item_name_length       = 0;
        my $phys_print_name_length = 0;
        foreach my $converted_file ( @{ $converted_files{$file_type} } ) {
            my $item_name = basename( $converted_file->{input_file}, ".ini" );
            $item_name_length = length($item_name)
              if length($item_name) > $item_name_length;
            $columns{error_col}{width} = length( $converted_file->{error} )
              if length( $converted_file->{error} ) >
              $columns{error_col}{width};
            push @{ $columns{slicer_col}{content} },
              $converted_file->{slicer_flavor};
            push @{ $columns{item_name_col}{content} }, $item_name;
            push @{ $columns{converted_col}{content} },
              $converted_file->{success};
            push @{ $columns{error_col}{content} }, $converted_file->{error};
            if ( $file_type eq 'Printer' ) {
                my $phys_print_name = $converted_file->{physical_printer_file};
                $phys_print_name_length = length($phys_print_name)
                  if length($phys_print_name) > $phys_print_name_length;
                push @{ $columns{phys_printer_col}{content} }, $phys_print_name;
            }
        }

        # Optimize heading and width of "Profile Name" column
        $columns{item_name_col}{width} =
          ( $columns{item_name_col}{width} > $item_name_length )
          ? $item_name_length
          : $columns{item_name_col}{width};
        if ( $item_name_length < length( $columns{item_name_col}{name} ) ) {
            $columns{item_name_col}{name} = "$file_type Profile\nName";
            $columns{item_name_col}{width} =
              ( length( $file_type . " Profile" ) < $item_name_length )
              ? $item_name_length
              : length( $file_type . " Profile" );
        }

        # Add "Physical Printer" column for printer profile conversions
        if ( $file_type eq 'Printer' ) {
            $phys_print_name_length =
              ( $phys_print_name_length < 17 ) ? 17 : $phys_print_name_length;
            if ( $phys_print_name_length >= 30 ) {
                $columns{phys_printer_col}{name} =
                  "Imported Physical Printer Data";
            }
        }

        my @column_headings = ();
        my @table_rows      = ();
        my $total_rows      = 0;

        # Build table columns
        foreach my $col (@column_order) {
            if ( $columns{$col}{width} > 0 ) {
                push @column_headings,
                  [ $columns{$col}{width}, $columns{$col}{name} ];
                my $content_rows = scalar @{ $columns{$col}{content} };
                $total_rows = $content_rows if $content_rows > $total_rows;
            }
        }

        # Build table rows
        for my $i ( 0 .. $total_rows - 1 ) {
            my @row = ();
            foreach my $col (@column_order) {
                if ( $columns{$col}{width} > 0 ) {
                    my $content_item = $columns{$col}{content}[$i]
                      // "";    # Use empty string if content array is shorter
                    push @row, $content_item;
                }
            }
            push @table_rows, \@row;
        }

        my $table = Text::SimpleTable->new(@column_headings);

        foreach my $row (@table_rows) {
            $table->row( @{$row} );
        }

        my $new_indent = int( ( get_table_width() - length($outstring) ) / 2 );
        $indent = $new_indent if $new_indent > $indent;

        $tables{$file_type} = $table;
    }
    print ' ' x $indent . "\e[1;32m$outstring\e[0m\n";
    for my $type ( keys %tables ) {
        print "\n\e[1m$type Files Converted\e[0m\n";
        print $tables{$type}->draw();
    }
    print "\nSource Directory:      $input_dir\n";
    print "Destination Directory: $output_dir\n";
    exit;
}