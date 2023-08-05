#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long;
use File::Basename;
use File::Glob ':glob';
use File::Spec;
use List::Util;
use String::Escape qw(unbackslash);
use JSON;

# Constants
my $ORCA_SLICER_VERSION = '1.6.0.0';

# Subroutine to print usage instructions and exit
sub print_usage_and_exit {
    my $usage = <<"END_USAGE";
Usage: $0 [options]

Options:
    --input <PATTERN>     Specifies the input SuperSlicer INI file(s). (Required)
                          You can use wildcards to specify multiple files.
    --outdir <DIRECTORY>  Specifies the output directory where the JSON files will be saved. (Required)
    --overwrite           Allows overwriting existing output files. If not specified, the script will
                          exit with a warning if the output file already exists.
    -h, --help            Displays this usage information.

END_USAGE

    print $usage;
    exit(1);
}

# Initialize variables to store command-line options
my @input_files;
my $output_directory;
my $overwrite;

# Parse command-line options
GetOptions(
    "input=s@"  => \@input_files,
    "outdir=s"  => \$output_directory,
    "overwrite" => \$overwrite,
    "h|help"    => sub { print_usage_and_exit(); },
) or die("Error in command-line arguments.\n");

# Check if required options are provided
if ( !@input_files || !$output_directory ) {
    print_usage_and_exit();
}

# Check if the output directory exists...
unless ( -d $output_directory ) {
    die("Output directory $output_directory cannot be found.\n");
}

# ...and is writable
unless ( -w $output_directory ) {
    die("Output directory $output_directory is not writable.\n");
}

# Define parameter mappings for translating the SuperSlicer INI settings
# to Orca Slicer JSON keys
my %print_parameter_map = (
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
    avoid_crossing_perimeters_max_detour     => 'max_travel_detour_distance',
    min_bead_width                           => 'min_bead_width',
    min_feature_size                         => 'min_feature_size',
    solid_infill_below_area                  => 'minimum_sparse_infill_area',
    only_one_perimeter_first_layer           => 'only_one_wall_first_layer',
    only_one_perimeter_top                   => 'only_one_wall_top',
    ooze_prevention                          => 'ooze_prevention',
    external_perimeter_acceleration          => 'outer_wall_acceleration',
    external_perimeter_extrusion_width       => 'outer_wall_line_width',
    post_process                             => 'post_process',
    wipe_tower_brim_width                    => 'prime_tower_brim_width',
    wipe_tower_width                         => 'prime_tower_width',
    raft_contact_distance                    => 'raft_contact_distance',
    raft_expansion                           => 'raft_expansion',
    raft_first_layer_density                 => 'raft_first_layer_density',
    raft_first_layer_expansion               => 'raft_first_layer_expansion',
    raft_layers                              => 'raft_layers',
    avoid_crossing_perimeters                => 'reduce_crossing_wall',
    only_retract_when_crossing_perimeters    => 'reduce_infill_retraction',
    resolution                               => 'resolution',
    seam_position                            => 'seam_position',
    skirt_distance                           => 'skirt_distance',
    skirt_height                             => 'skirt_height',
    skirts                                   => 'skirt_loops',
    slice_closing_radius                     => 'slice_closing_radius',
    slicing_mode                             => 'slicing_mode',
    small_perimeter_min_length               => 'small_perimeter_threshold',
    infill_acceleration                      => 'sparse_infill_acceleration',
    fill_density                             => 'sparse_infill_density',
    infill_extrusion_width                   => 'sparse_infill_line_width',
    staggered_inner_seams                    => 'staggered_inner_seams',
    standby_temperature_delta                => 'standby_temperature_delta',
    support_material                         => 'enable_support',
    support_material_angle                   => 'support_angle',
    support_material_enforce_layers          => 'enforce_support_layers',
    support_material_spacing                 => 'support_base_pattern_spacing',
    support_material_contact_distance        => 'support_top_z_distance',
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
    wall_transition_filter_deviation   => 'wall_transition_filter_deviation',
    wall_transition_length             => 'wall_transition_length',
    wipe_tower_no_sparse_layers        => 'wipe_tower_no_sparse_layers',
    xy_size_compensation               => 'xy_contour_compensation',
    xy_inner_size_compensation         => 'xy_hole_compensation',
    support_material_layer_height      => 'independent_support_layer_height',
    fill_pattern                       => 'sparse_infill_pattern',
    output_filename_format             => 'filename_format',
    support_material_pattern           => 'support_base_pattern',
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
);

# Define parameter mappings for translating the SuperSlicer INI settings
# to Orca Slicer JSON keys
my %filament_parameter_map = (
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
    filament_retract_layer_change  => 'filament_retract_when_changing_layer',
    filament_retract_length        => 'filament_retraction_length',
    filament_retract_lift          => 'filament_z_hop',
    filament_retract_lift_above    => 'filament_retract_lift_above',
    filament_retract_lift_below    => 'filament_retract_lift_below',
    filament_retract_restart_extra => 'filament_retract_restart_extra',
    filament_retract_speed         => 'filament_retraction_speed',
    filament_shrink                => 'filament_shrink',
    filament_soluble               => 'filament_soluble',
    filament_type                  => 'filament_type',
    filament_wipe                  => 'filament_wipe',
    first_layer_bed_temperature    => [
        'hot_plate_temp_initial_layer', 'cool_plate_temp_initial_layer',
        'eng_plate_temp_initial_layer', 'textured_plate_temp_initial_layer'
    ],
    first_layer_temperature              => 'nozzle_temperature_initial_layer',
    full_fan_speed_layer                 => 'full_fan_speed_layer',
    inherits                             => 'inherits',
    max_fan_speed                        => 'fan_max_speed',
    min_fan_speed                        => 'fan_min_speed',
    min_print_speed                      => 'slow_down_min_speed',
    slowdown_below_layer_time            => 'slow_down_layer_time',
    start_filament_gcode                 => 'filament_start_gcode',
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

# Initialize a hash to store translated JSON data
my %new_hash = ();

# Initialize a variable to keep track of maximum filament temp
my $max_temp = 0;    

# Subroutine to detect what type of ini file it's being fed
sub detect_ini_type {
    my %source_ini = @_;
    my ($filament_count, $print_count) = 0,0;
    foreach my $parameter ( keys %source_ini ) {
        $filament_count += 1 if exists $filament_parameter_map{$parameter};
        $print_count += 1 if exists $print_parameter_map{$parameter};
    }
    return ($filament_count > $print_count)? 'filament' : 'print';
}

sub convert_filament_params {
    my ( $parameter, %source_ini ) = @_;

    # Ignore SuperSlicer parameters that Orca Slicer doesn't support
    return unless exists $filament_parameter_map{$parameter};

    # Get the value of the current parameter from the INI file
    my $new_value = $source_ini{$parameter};

    # If the SuperSlicer value is 'nil,' skip this parameter and let
    # Orca Slicer use its own default
    return if ( $new_value eq 'nil' );

    # Check if the parameter maps to multiple keys in the JSON data
    if ( ref( $filament_parameter_map{$parameter} ) eq 'ARRAY' ) {

        # If yes, set the same value for each key in the JSON data
        $new_hash{$_} = $new_value for @{ $filament_parameter_map{$parameter} };
        return;
    }

    # Handle special cases for specific parameter keys
    if ( $parameter =~ /^(start_filament_gcode|end_filament_gcode)/ ) {

        # The custom gcode blocks need to be unquoted and unbackslashed
        # before JSON encoding
        $new_value =~ s/^"(.*)"$/$1/;
        $new_value = [ unbackslash($new_value) ];
    }
    elsif ( $parameter eq 'filament_type' ) {

        # Translate filament type to a specific value if it exists in
        # the mapping, otherwise keep the original value
        $new_value = $filament_types{$new_value} // $new_value;
    }
    elsif ( $parameter eq 'filament_max_volumetric_speed' ) {

        # Max volumetric speed can't be zero so use a reasonable default
        # if necessary
        my $mvs =
          ( $new_value > 0 )
          ? $new_value
          : $default_MVS{ $source_ini{'filament_type'} };
        $new_value = "" . $mvs;    # Must cast as a string before JSON encoding
    }
    elsif ( $parameter eq 'external_perimeter_fan_speed' ) {

        # 'external_perimeter_fan_speed' in SS is the closest equivalent to
        # 'overhang_fan_threshold' in Orca, so convert to percentage
        $new_value = ( $new_value < 0 ) ? '0%' : "$new_value%";
    }
    return $new_value;
}

# Subroutine to parse an .ini file and return a hash with all key/value pairs
sub ini_reader {
    my ($filename) = @_;

    open my $fh, '<', $filename or die "Cannot open '$filename': $!\n";
    my %config;
    my $flavor = undef;

    while ( my $line = <$fh> ) {

        # Detect which slicer we're importing from
        $flavor = $1 if ( $line =~ /^#\s*generated\s+by\s+(\S+)/i );

        next if $line =~ /^\s*(?:#|$)/;    # Skip empty and comment lines

        my ( $key, $value ) =
          map { s/^\s+|\s+$//gr } split /\s* = \s*/, $line, 2;
        $config{$key} = $value;
    }
    close $fh;
    return $flavor, %config;
}

###################
#                 #
#    MAIN LOOP    #
#                 #
###################

# Expand wildcards and process each input file
my @expanded_input_files;
foreach my $pattern (@input_files) {
    push @expanded_input_files, bsd_glob($pattern);
}

foreach my $input_file (@expanded_input_files) {

    # Extract filename, directory, and extension from the input file
    my ( $file, $dir, $ext ) = fileparse( $input_file, qr/\.[^.]*/ );
   
    # Clear the JSON hash and reset tracking variables
    %new_hash = ();
    $max_temp = 0; 

    # Read the input INI file and set source slicer flavor
    my ($slicer_flavor, %source_ini) = ini_reader($input_file)
      or die "Error reading $input_file: $!";

    if (!defined $slicer_flavor) {
        die "Could not detect slicer flavor for $input_file!";
    }

    my $ini_type = detect_ini_type(%source_ini);
    
    #print "This is a $ini_type config file generated by $slicer_flavor!\n";
    #next;

    # Loop through each parameter in the INI file
    foreach my $parameter ( keys %source_ini ) {

        my $new_value = undef;

        if ($ini_type eq 'filament') {
            $new_value = convert_filament_params( $parameter, %source_ini );
        }

        # Move on if we didn't get a usable value. Otherwise, set the translated
        # value in the JSON data
        ( defined $new_value )
          ? $new_hash{ $filament_parameter_map{$parameter} } = $new_value
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

    # Add additional filament metadata to the JSON data
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


    # Construct the output filename
    my $output_file = File::Spec->catfile( $output_directory, $file . ".json" );

    # Check if the output file already exists and handle overwrite option
    if ( -e $output_file && !$overwrite ) {
        die "Output file '$output_file' already exists. 
          Use --overwrite to force overwriting.\n";
    }

    # Write the JSON data to the output file
    open my $fh, '>', $output_file
      or die "Cannot open '$output_file' for writing: $!";
    my $json = JSON->new->pretty->encode( \%new_hash );
    print $fh $json;
    close $fh;

    print "\nTranslated '$input_file' to '$output_file'.\n";
}
