#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long;
use File::Basename;
use File::Glob ':glob';
use Path::Class;
use String::Escape qw(unbackslash);
use Term::Choose;
use JSON;

# Constants
my $ORCA_SLICER_VERSION = '1.6.0.0';

# Subroutine to print usage instructions and exit
sub print_usage_and_exit {
    my $usage = <<'END_USAGE';
Usage: $0 [options]

Options:
  --input <PATTERN>             Specifies the input PrusaSlicer or SuperSlicer
                                INI file(s). (Required) You can use wildcards
                                to specify multiple files.

  --outdir <DIRECTORY>          Specifies the ROOT OrcaSlicer settings directory.
                                (Required) The typical locations by OS are:      
                   in Windows:  C:\Users\%USERNAME%\AppData\Roaming\OrcaSlicer
                     in MacOS:  ~/Library/Application Support/OrcaSlicer
                     in Linux:  ~/.config/OrcaSlicer

  --nozzle-size <DECIMAL>       For print profiles, specifies the diameter (in 
                                mm) of the nozzle the print profile is
                                intended to be used with (e.g. --nozzle-size
                                0.4). If this is not specified, the script will
                                use twice the layer height as a proxy for the
                                nozzle width. (Optional)

  --physical-printer <PATTERN>  Specifies the INI file for the corresponding
                                "physical printer" when converting printer
                                config files. If this option is not used, the
                                converted OrcaSlicer "machine" configuration
                                may lack network-configuration data. (Optional)

  --overwrite                   Allows overwriting existing output files. If
                                not specified, the script will exit with a
                                warning if the output file already exists. 
                                (Optional)

  --force-output                Forces the script to output the converted JSON
                                files to the specified output directory. Use this
                                option if you do not want the new files to be
                                placed in your OrcaSlicer settings folder.
                                (Optional)

  -h, --help                    Displays this usage information.
END_USAGE

    print $usage;
    exit(1);
}

# Initialize variables to store command-line options
my @input_files;
my ( $output_directory, $nozzle_size, $physical_printer, $overwrite,
    $force_out );

# Parse command-line options
GetOptions(
    "input=s@"           => \@input_files,
    "outdir=s"           => \$output_directory,
    "overwrite"          => \$overwrite,
    "nozzle-size"        => \$nozzle_size,
    "physical-printer:s" => \$physical_printer,
    "force-output"       => \$force_out,
    "h|help"             => sub { print_usage_and_exit(); },
) or die("Error in command-line arguments.\n");

# Mapping of output directories by ini type
my %output_directories = (
    'filament' => [ 'user', 'default', 'filament' ],
    'print'    => [ 'user', 'default', 'process' ],
    'printer'  => [ 'user', 'default', 'machine' ]
);

# Check if required options are provided
if ( !@input_files || !$output_directory ) {
    print_usage_and_exit();
}

# Subroutine to verify output directory before writing
sub check_output_directory {
    my ($directory) = @_;
    my $die_msg = "\nOutput directory $directory cannot be found.\n";
    unless ($force_out) {
        $die_msg =
            $die_msg
          . "Are you sure that $output_directory is the correct ROOT directory "
          . "of your OrcaSlicer installation?\n(Run this script with the -h "
          . "flag for more info.\n";
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
my %new_hash = ();
my $max_temp = 0;
my ( $slicer_flavor, $ini_type, $external_perimeters_first,
    $infill_first, $ironing, $ironing_type );

# Initialize hash of parameters that will update tracking variables
my %param_to_var = (
    'external_perimeters_first' => \$external_perimeters_first,
    'infill_first'              => \$infill_first,
    'ironing'                   => \$ironing,
);

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
    return split( /,/, $input_string );
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
    return ( $new_float > 2 ) ? '2' : $new_float;
}

# Subroutine to convert percentage value to millimeters
sub percent_to_mm {
    my ( $comp, $subject_param ) = @_;

    if ( defined $subject_param
        && !is_percent($subject_param) )
    {
        return $subject_param;
    }

    if ( !is_percent($comp) ) {
        return "" . ($comp * ( remove_percent($subject_param) / 100 ));
    }

    return undef;
}

# Subroutine to convert millimeter values to percentage
sub mm_to_percent {
    my ( $comp, $subject_param ) = @_;

    if ( defined $subject_param
        && is_percent($subject_param) )
    {
        return $subject_param;
    }

    if ( !is_percent($comp) ) {
        return ( ( $subject_param / $comp ) * 100 );
    }

    return undef;
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
        brim_separation                 => 'brim_object_gap',
        brim_width                      => 'brim_width',
        compatible_printers_condition   => 'compatible_printers_condition',
        compatible_printers             => 'compatible_printers',
        default_acceleration            => 'default_acceleration',
        overhangs                       => 'detect_overhang_wall',
        thin_walls                      => 'detect_thin_wall',
        draft_shield                    => 'draft_shield',
        first_layer_size_compensation   => 'elefant_foot_compensation',
        enable_dynamic_overhang_speeds  => 'enable_overhang_speed',
        wipe_tower                      => 'enable_prime_tower',
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
        travel_acceleration                => 'travel_acceleration',
        travel_speed_z                     => 'travel_speed_z',
        travel_speed                       => 'travel_speed',
        support_tree_angle                 => 'tree_support_branch_angle',
        support_tree_branch_diameter       => 'tree_support_branch_diameter',
        wall_distribution_count            => 'wall_distribution_count',
        perimeter_generator                => 'wall_generator',
        perimeters                         => 'wall_loops',
        wall_transition_angle              => 'wall_transition_angle',
        wall_transition_filter_deviation => 'wall_transition_filter_deviation',
        wall_transition_length           => 'wall_transition_length',
        wipe_tower_no_sparse_layers      => 'wipe_tower_no_sparse_layers',
        xy_size_compensation             => 'xy_contour_compensation',
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
        infill_every_layers                => 'infill_combination',
        complete_objects                   => 'print_sequence',
        brim_type                          => 'brim_type',
        support_material_style             => 1,
        ironing                            => 1,
        ironing_type                       => 1,
        external_perimeters_first          => 1,
        infill_first                       => 1
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
        filament_colour                => 'default_filament_colour',
        filament_cost                  => 'filament_cost',
        filament_density               => 'filament_density',
        filament_deretract_speed       => 'filament_deretraction_speed',
        filament_diameter              => 'filament_diameter',
        filament_max_volumetric_speed  => 'filament_max_volumetric_speed',
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
        retract_before_travel            => 'retraction_minimum_travel',
        retract_speed                    => 'retraction_speed',
        silent_mode                      => 'silent_mode',
        single_extruder_multi_material   => 'single_extruder_multi_material',
        thumbnails                       => 'thumbnails',
        template_custom_gcode            => 'template_custom_gcode',
        wipe                             => 'wipe'
    },
    'physical_printer' => {
        host_type                    => 1,
        preset_name                  => 1,
        preset_names                 => 1,
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
    retract_lift_top                    => 'single',
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
    organic => [ 'tree',   'default' ]
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
    marlin2        => 'marlin',
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
    repetier  => 'repetier',
    prusalink => 'prusalink',
    octoprint => 'octoprint',
    moonraker => 'octoprint',
    mks       => 'mks',
    klipper   => 'octoprint',
    flashair  => 'flashair',
    duet      => 'duet',
    astrobox  => 'astrobox',
);

# Mapping of Z-hop enforcement schemes
my %zhop_enforcement = (
    'All surfaces' => 'All Surfaces',
    'Not on top'   => 'Bottom Only',
    'Only on top'  => 'Top Only',
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

    # Check if all counts are less than 10; return undef if true
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
    my ( $parameter, %source_ini ) = @_;

    # Get the value of the current parameter from the INI file
    my $new_value = $source_ini{$parameter} // undef;

    # If the SuperSlicer value is 'nil,' skip this parameter and let
    # Orca Slicer use its own default
    return undef if defined $new_value && $new_value eq 'nil';

    # Some printer parameters need to be converted to arrays
    if ( exists $multivalue_params{$parameter} ) {
        $new_value = [ multivalue_to_array($new_value) ];
        if ($multivalue_params{$parameter} eq 'single'){
            $new_value = $new_value->[0];
        }
    }

    # SuperSlicer has a "default_speed" parameter that PrusaSlicer doesn't,
    # and a lot of percentages are based on that default
    my $default_speed = $source_ini{'default_speed'}
      if ( $slicer_flavor eq 'SuperSlicer' );

    # Check if the parameter maps to multiple keys in the JSON data
    if ( ref( $parameter_map{$ini_type}{$parameter} ) eq 'ARRAY' ) {

        # If yes, set the same value for each key in the JSON data
        $new_hash{$_} = $new_value
          for @{ $parameter_map{$ini_type}{$parameter} };
        return;
    }

    # Track state of combination settings
    if ( exists $param_to_var{$parameter} ) {
        ${ $param_to_var{$parameter} } = $new_value ? 1 : 0;
        return;
    }

    my $unbackslash_gcode = sub {
        $new_value =~ s/^"(.*)"$/$1/;
        $new_value = [ unbackslash($new_value) ];
        return $new_value;
    };

    # Dispatch table for handling special cases
    my %special_cases = (

        # The custom gcode blocks need to be unquoted and unbackslashed
        # before JSON encoding
        'start_filament_gcode'  => $unbackslash_gcode,
        'end_filament_gcode'    => $unbackslash_gcode,
        'post_process'          => $unbackslash_gcode,
        'before_layer_gcode'    => $unbackslash_gcode,
        'toolchange_gcode'      => $unbackslash_gcode,
        'layer_gcode'           => $unbackslash_gcode,
        'end_gcode'             => $unbackslash_gcode,
        'pause_print_gcode'     => $unbackslash_gcode,
        'start_gcode'           => $unbackslash_gcode,
        'template_custom_gcode' => $unbackslash_gcode,

        'default_filament_profile' => sub {
            my @new_array = split( /;/, $new_value );
            return \@new_array;
        },

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

        # 'external_perimeter_fan_speed' in SS is the closest equivalent to
        # 'overhang_fan_threshold' in Orca, so convert to percentage
        'external_perimeter_fan_speed' => sub {
            return ( $new_value < 0 ) ? '0%' : "$new_value%";
        },

        # Catch ironing_type and update tracking variable
        'ironing_type' => sub {
            $ironing_type = $new_value;
            return;
        },

        'retract_lift_top' => sub {
            my @new_array;
            foreach my $value (@$new_value) {
                push @new_array, $zhop_enforcement{$new_value};
            }
            return \@new_array;
        },

        # Some values may need to be converted from percent of nozzle width to
        # absolute value in mm
        'max_layer_height' => sub {
            return percent_to_mm( $nozzle_size, $new_value )
        },
        'min_layer_height' => sub {
            return percent_to_mm( $nozzle_size, $new_value )
        },
        'fuzzy_skin_point_dist' => sub {
            return percent_to_mm( $nozzle_size, $new_value );
        },
        'fuzzy_skin_thickness' => sub {
            return percent_to_mm( $nozzle_size, $new_value );
        },
        'small_perimeter_min_length' => sub {
            return percent_to_mm( $nozzle_size, $new_value );
        },

        # Convert percents to float, capping at 2 as OrcaSlicer expects
        'bridge_flow_ratio'   => sub { return percent_to_float($new_value) },
        'fill_top_flow_ratio' => sub { return percent_to_float($new_value) },

        'wall_transition_length' => sub {
            return mm_to_percent( $nozzle_size, $new_value );
        },

        # Option "0" means "same as top," so set that manually
        'support_material_bottom_contact_distance' => sub {
            if ( $new_value eq '0' ) {
                return $source_ini{'support_material_contact_distance'};
            }
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
            return;
        },

        # Translate infill types
        'fill_pattern'        => sub { return $infill_types{$new_value} },
        'top_fill_pattern'    => sub { return $infill_types{$new_value} },
        'bottom_fill_pattern' => sub { return $infill_types{$new_value} },

        'gcode_flavor' => sub { return $gcode_flavors{$new_value} // undef; },

        'host_type' => sub { return $host_types{$new_value} },

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
                $new_value = percent_to_mm( $nozzle_size, $new_value );
            }
            return defined $new_value ? "" . $new_value : undef;
        },

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
                ( $slicer_flavor eq 'PrusaSlicer' )
                ? $source_ini{'first_layer_speed'}
                : $new_value );
        },

        # PrusaSlicer calculates solid infill speed as a percentage of sparse
        'solid_infill_speed' => sub {
            return percent_to_mm(
                ( $slicer_flavor eq 'PrusaSlicer' )
                ? $source_ini{'infill_speed'}
                : $default_speed,
                $new_value
            );
        },

        'perimeter_speed' => sub {
            return ( $slicer_flavor eq 'SuperSlicer' )
              ? percent_to_mm( $default_speed, $new_value )
              : $new_value;
        },

        'support_material_speed' => sub {
            return ( $slicer_flavor eq 'SuperSlicer' )
              ? percent_to_mm( $default_speed, $new_value )
              : $new_value;
        },

        'bridge_speed' => sub {
            return ( $slicer_flavor eq 'SuperSlicer' )
              ? percent_to_mm( $default_speed, $new_value )
              : $new_value;
        },

        'infill_speed' => sub {
            return ( $slicer_flavor eq 'SuperSlicer' )
              ? percent_to_mm( $new_hash{'internal_solid_infill_speed'},
                $new_value )
              : $new_value;
        },

        'small_perimeter_speed' => sub {
            return ( $slicer_flavor eq 'SuperSlicer' )
              ? percent_to_mm( $new_hash{'sparse_infill_speed'}, $new_value )
              : $new_value;
        },

        'gap_fill_speed' => sub {
            return ( $slicer_flavor eq 'SuperSlicer' )
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

        my $new_value = convert_params( $parameter, %source_ini );

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
      evaluate_print_order( $external_perimeters_first, $infill_first );

    # Set the ironing type based on the tracked options
    $new_hash{'ironing_type'} =
      evaluate_ironing_type( $ironing, $ironing_type );

    return %new_hash;
}

# Subroutine to parse physical printer config if specified
sub handle_physical_printer {
    my ($input_file) = @_;
    my $sys_dir = dir( $output_directory, 'system' );
    my %unique_names;
    foreach my $file ( $sys_dir->children ) {
        next unless -f $file && $file->basename =~ qr/\.json$/;
        my $json_data = file($file)->slurp();
        for my $machine ( @{ decode_json($json_data)->{machine_list} } ) {
            my $name = $machine->{name};
            $unique_names{$name} = 1 if $name !~ /common/i;
        }
    }
    my %menu_options = (
        info => 'In OrcaSlicer, a "machine" profile must be associated with a '
          . 'printer selected and configured from the available system presets. '
          . 'Below is a list of the configured printers that '
          . 'have been detected on your system.' . "\n\n"
          . 'If you do not see the printer you wish to associate with this '
          . 'profile, choose <QUIT> to exit this script, configure your desired '
          . 'printer in OrcaSlicer, and then run this script again. '
          . 'Alternatively, you may select <NONE> to proceed without associating '
          . 'this "machine" profile with a configured printer, but network '
          . "configuration and g-code upload will not be available.\n",
        prompt => 'Please choose an OrcaSlicer printer to '
          . "associate with $input_file:\n",
        clear_screen => 1,
        layout       => 2
    );
    my @menu_items = ( keys %unique_names, '<NONE>', '<QUIT>' );
    my $choice     = Term::Choose::choose( \@menu_items, \%menu_options );

    exit         if $choice eq '<QUIT>';
    $choice = '' if $choice eq '<NONE>';

    my %printer_hash = ();
    my %printer_ini  = ini_reader( file($physical_printer) )
      or die "Error reading $physical_printer: $!";
    foreach my $parameter ( keys %printer_ini ) {

        # Ignore parameters that Orca Slicer doesn't support
        next unless exists $parameter_map{'physical_printer'}{$parameter};

        my $new_value = convert_params( $parameter, %printer_ini );

        next if $new_value eq "";

        # Set the translated value in the JSON data
        $printer_hash{$parameter} = $new_value // "";
    }
    $printer_hash{'inherits'} = $choice;
    return %printer_hash;
}


# Subroutine to parse an .ini file and return a hash with all key/value pairs
sub ini_reader {
    my ($file) = @_;
    my %config;
    $slicer_flavor = undef;
    foreach my $line ( $file->slurp() ) {

        # Detect which slicer we're importing from
        $slicer_flavor = $1 if ( $line =~ /^#\s*generated\s+by\s+(\S+)/i );

        next if $line =~ /^\s*(?:#|$)/;    # Skip empty and comment lines
        my ( $key, $value ) =
          map { s/^\s+|\s+$//gr } split /\s* = \s*/, $line, 2;
        $config{$key} = $value;
    }
    return %config;
}

###################
#                 #
#    MAIN LOOP    #
#                 #
###################

# Expand wildcards and process each input file
my @expanded_input_files;
foreach my $pattern (@input_files) {
    my @iterator =
      ( -d $pattern ) ? dir($pattern)->children : bsd_glob($pattern);
    foreach my $file (@iterator) {
        next unless -f $file && file($file)->basename =~ qr/\.ini$/;
        push @expanded_input_files, file($file);
    }
}

foreach my $input_file (@expanded_input_files) {

    # Extract filename and directory from the input file
    my $dir  = $input_file->dir;
    my $file = basename( $input_file->basename, ".ini" );

    # Reset tracking variables and hashes
    %new_hash = ();
    $max_temp = 0;
    foreach ( \$ini_type, \$external_perimeters_first, \$infill_first,
        \$ironing, \$ironing_type )
    {
        $$_ //= undef;
    }
    %param_to_var = (
        'external_perimeters_first' => \$external_perimeters_first,
        'infill_first'              => \$infill_first,
        'ironing'                   => \$ironing,
    );

    # Read the input INI file and set source slicer flavor
    my %source_ini = ini_reader($input_file)
      or die "Error reading $input_file: $!";

    if ( !defined $slicer_flavor ) {
        print "Could not detect slicer flavor for $input_file! Skipping...\n";
        next;
    }

    $ini_type = detect_ini_type(%source_ini);
    if ( !defined $ini_type ) {
        print "Skipping $input_file because it does not appear "
          . "to be a supported config file!\n";
        next;
    }

    # Make sure output directory is correct
    my $subdir =
      $force_out
      ? dir($output_directory)
      : dir( $output_directory, @{ $output_directories{$ini_type} } );

    check_output_directory($subdir);

    # If nozzle size isn't specified or detected, use 2x layer size as a proxy
    if ( exists $source_ini{'nozzle_diameter'} ) {
        my @nozzle_diameters =
          multivalue_to_array( $source_ini{'nozzle_diameter'} );
        $nozzle_size = $nozzle_diameters[0];
    }
    if ( ( !defined $nozzle_size ) && ( $ini_type eq 'print' ) ) {
        my $layer_height = $source_ini{'layer_height'}
          or die
          "ERROR: layer_height parameter not found. Is $input_file a valid 
          PrusaSlicer/SuperSlicer profile .ini file?\n";
        $nozzle_size = 2 * $source_ini{'layer_height'};
    }

    # Loop through each parameter in the INI file
    foreach my $parameter ( keys %source_ini ) {

        # Ignore parameters that Orca Slicer doesn't support
        next unless exists $parameter_map{$ini_type}{$parameter};

        my $new_value = convert_params( $parameter, %source_ini );

        # Move on if we didn't get a usable value. Otherwise, set the translated
        # value in the JSON data
        ( defined $new_value )
          ? $new_hash{ $parameter_map{$ini_type}{$parameter} } = $new_value
          : next;

        # Track the maximum commanded nozzle temperature
        $max_temp = $new_value
          if $parameter =~ /^(first_layer_temperature|temperature)$/
          && $new_value > $max_temp;
    }

    # Add additional general metadata to the JSON data
    %new_hash = (
        %new_hash,
        $ini_type . "_settings_id" => $file,
        name                       => $file,
        from                       => 'User',
        is_custom_defined          => '1',
        version                    => $ORCA_SLICER_VERSION
    );

    # Add additional profile-specific metadata to the JSON data
    if ( $ini_type eq 'filament' ) {
        %new_hash = (
            %new_hash,
            nozzle_temperature_range_low  => '0',
            nozzle_temperature_range_high => "" . $max_temp,
            slow_down_for_layer_cooling   => (
                ( $source_ini{'slowdown_below_layer_time'} > 0 )
                ? '1'
                : '0'
            )
        );
    }
    elsif ( $ini_type eq 'print' ) {
        %new_hash = ( calculate_print_params(%source_ini) );
    }
    elsif ( ( $ini_type eq 'printer' ) && ( defined $physical_printer ) ) {
        %new_hash = ( %new_hash, handle_physical_printer($file) );
    }

    my $output_file = file( $subdir, "$file.json" );

    # Check if the output file already exists and handle overwrite option
    if ( -e $output_file && !$overwrite ) {
        die "Output file '$output_file' already exists.\n"
          . "Use --overwrite to force overwriting.\n";
    }

    # Write the JSON data to the output file
    $output_file->spew( JSON->new->pretty->canonical->encode( \%new_hash ) );

    print "\nTranslated '$input_file', a $ini_type config file generated by "
      . "$slicer_flavor, to '$output_file'.\n";
}
