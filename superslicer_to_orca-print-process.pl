#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long;
use File::Basename;
use File::Glob ':glob';
use String::Escape qw(unbackslash);
use Config::Tiny;
use JSON;

# Constants
my $ORCA_SLICER_VERSION = '1.6.0.0';

# Subroutine to print usage instructions and exit
sub print_usage_and_exit {
    my $usage = <<"END_USAGE";
Usage: $0 [options]

Options:
    --input <PATTERN>     Specifies the input PrusaSlicer or SuperSlicer INI file(s). (Required)
                          You can use wildcards to specify multiple files.
    --outdir <DIRECTORY>  Specifies the output directory where the JSON files will be saved. (Required)
    --overwrite           Allows overwriting existing output files. If not specified, the script will
                          exit with a warning if the output file already exists.
    --nozzle-size         Specifies the diameter (in mm) of the nozzle the print profile is intended
                          to be used with (e.g. --nozzle-size 0.4). This is needed because some
                          parameters must be calculated by reference to the nozzle size, but PrusaSlicer
                          and SuperSlicer print profiles do not store the nozzle size. If this is not
                          specified, the script will use twice the layer height as a proxy for the nozzle
                          width. (Optional)
    -h, --help            Displays this usage information.

END_USAGE

    print $usage;
    exit(1);
}

# Initialize variables to store command-line options
my @input_files;
my $output_directory;
my $nozzle_size;
my $overwrite;

# Parse command-line options
GetOptions(
    "input=s@"    => \@input_files,
    "outdir=s"    => \$output_directory,
    "overwrite"   => \$overwrite,
    "nozzle-size" => \$nozzle_size,
    "h|help"      => sub { print_usage_and_exit(); },
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

# Subroutine to detect which slicer we're importing from
sub slicer_flavor {
    my $input_file = $_[0];

    open my $fh, '<', $input_file or die "Cannot open '$input_file': $!\n";
    while ( my $line = <$fh> ) {
        if ( $line =~ /^#\s*generated\s+by\s+(\S+)/i ) {
            close $fh;
            return $1;
        }
    }
    close $fh;

    return undef;
}

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

# Subroutine to convert percentage value to millimeters
sub percent_to_mm {
    my ( $first_comp, $second_comp, $subject_param ) = @_;

    if ( defined $subject_param
        && !is_percent($subject_param) )
    {
        return $subject_param;
    }

    for my $component ( $first_comp, $second_comp ) {
        if ( !is_percent($component) ) {
            return $component * ( remove_percent($subject_param) / 100 );
        }
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

# Define parameter mappings for translating the SuperSlicer INI settings
# to Orca Slicer JSON keys
my %parameter_map = (
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

# Expand wildcards and process each input file
my @expanded_input_files;
foreach my $pattern (@input_files) {
    push @expanded_input_files, bsd_glob($pattern);
}

foreach my $input_file (@expanded_input_files) {

    # Extract filename, directory, and extension from the input file
    my ( $file, $dir, $ext ) = fileparse( $input_file, qr/\.[^.]*/ );

    # Detect input slicer flavor
    my $slicer_flavor = slicer_flavor($input_file);

    # Initialize a hash to store translated JSON data
    my %new_hash = ();

    # Initialize variables for tracking combination and other settings
    my ( $external_perimeters_first, $infill_first ) = undef, undef;
    my ( $ironing,                   $ironing_type ) = undef, undef;

    # Initialize hash of parameters that will update tracking variables
    my %param_to_var = (
        'external_perimeters_first' => \$external_perimeters_first,
        'infill_first'              => \$infill_first,
        'ironing'                   => \$ironing,
    );

    # Read the input INI file
    my $superslicer_ini = Config::Tiny->read( $input_file, 'utf8' )
      or die "Error reading $input_file: $!\n";

    # If nozzle size isn't specified, use twice layer size as a proxy
    unless ( defined $nozzle_size ) {
        my $layer_height = $superslicer_ini->{_}->{'layer_height'}
          or die
          "ERROR: layer_height parameter not found. Is $input_file a valid 
          PrusaSlicer/SuperSlicer print profile .ini file?\n";
        $nozzle_size = 2 * $superslicer_ini->{_}->{'layer_height'};
    }

    # Loop through each parameter in the INI file
    foreach my $parameter ( keys %{ $superslicer_ini->{_} } ) {

        # Ignore SuperSlicer parameters that Orca Slicer doesn't support
        next unless exists $parameter_map{$parameter};

        # Get the value of the current parameter from the INI file
        my $new_value = $superslicer_ini->{_}->{$parameter};

        # If the SuperSlicer value is 'nil,' skip this parameter and let
        # Orca Slicer use its own default
        next if ( $new_value eq 'nil' );

        # Handle special cases for specific parameter keys

        # Track state of combination settings
        if ( exists $param_to_var{$parameter} ) {
            ${ $param_to_var{$parameter} } = $new_value ? 1 : 0;
            next;
        }
        elsif ( $parameter eq 'ironing_type' ) {
            $ironing_type = $new_value;
            next;
        }

        if ( $parameter eq 'post_process' ) {

            # The custom gcode blocks need to be unquoted and unbackslashed
            # before JSON encoding
            $new_value =~ s/^"(.*)"$/$1/;
            $new_value = [ unbackslash($new_value) ];
        }

        if (   ( $parameter eq 'wall_transition_length' )
            && ( !is_percent($new_value) ) )
        {
            $new_value = mm_to_percent( $nozzle_size, $new_value );
        }

        # Option "0" means "same as top," so set that manually
        elsif (( $parameter eq 'support_material_bottom_contact_distance' )
            && ( $new_value eq '0' ) )
        {
            $new_value =
              $superslicer_ini->{_}->{'support_material_contact_distance'};
        }

        # OrcaSlicer consolidates three support-material options to two
        elsif ( $parameter eq 'support_material_style' ) {
            my ( $support_type, $support_style ) =
              @{ $support_styles{$new_value} };
            my $genstyle =
              ( !!$superslicer_ini->{_}->{'support_material_auto'} )
              ? 'auto'
              : 'manual';
            $new_hash{'support_type'}  = "${support_type}(${genstyle})";
            $new_hash{'support_style'} = $support_style;
            next;
        }

        # Translate infill types
        elsif ( $parameter =~
            /^(fill_pattern|top_fill_pattern|bottom_fill_pattern)$/ )
        {
            $new_value = $infill_types{$new_value};
        }

        # Set support pattern to default if we can't match the original pattern
        elsif ( $parameter eq 'support_material_pattern' ) {
            $new_value =
              ( exists $support_patterns{$new_value} ) ? $new_value : 'default';
        }

        # Set support interface pattern to auto if we can't match it
        elsif ( $parameter eq 'support_material_interface_pattern' ) {
            $new_value =
              ( exists $interface_patterns{$new_value} ) ? $new_value : 'auto';
        }

        # Translate seam position
        elsif ( $parameter eq 'seam_position' ) {
            $new_value = $seam_positions{$new_value};
        }

        # Assume that if support material layer height was specified, we want
        # independent support layer heights (true/false in OrcaSlicer)
        elsif ( $parameter eq 'support_material_layer_height' ) {
            $new_value = ( $new_value > 0 ) ? '1' : '0';
        }

        # OrcaSlicer uses angle brackets instead of square here
        elsif ( $parameter eq 'output_filename_format' ) {
            $new_value =~ s/\[|\]/ { $& eq '[' ? '{' : '}' } /eg;
        }

        # If this is a percent, try to calculate based on external extrusion
        # width. If that's also a percent, use double the layer height.
        elsif ( $parameter eq 'support_material_xy_spacing' ) {
            $new_value =
              percent_to_mm(
                $superslicer_ini->{_}->{'external_perimeter_extrusion_width'},
                $nozzle_size, $new_value );
            next if ( !defined $new_value );
            $new_value = "" . $new_value;
        }

        # Some values need to be converted from percent of nozzle width to
        # absolute value in mm
        elsif ( $parameter =~
/^(fuzzy_skin_point_dist|fuzzy_skin_thickness|small_perimeter_min_length)$/
          )
        {
            $new_value = percent_to_mm( $nozzle_size, undef, $new_value );
            next if ( !defined $new_value );
        }

        # Convert percents to float, capping at 2 as OrcaSlicer expects
        elsif ( $parameter =~ /^(bridge_flow_ratio|fill_top_flow_ratio)$/ ) {
            if ( is_percent($new_value) ) {
                my $new_float = remove_percent($new_value) / 100;
                $new_value = ( $new_float > 2 ) ? '2' : $new_float;
            }
        }

        # Convert numerical input to boolean
        elsif ( $parameter eq 'infill_every_layers' ) {
            $new_value = ( $new_value > 0 ) ? '1' : '0';
        }

        # Super/PrusaSlicer have this as boolean where OrcaSlicer offers
        # choices in a dropdown
        elsif ( $parameter eq 'complete_objects' ) {
            $new_value = ( !!$new_value ) ? 'by object' : 'by layer';
        }

        # Set the translated value in the JSON data
        $new_hash{ $parameter_map{$parameter} } = $new_value;
    }

    # Add additional metadata to the JSON data
    %new_hash = (
        %new_hash,
        print_settings_id => $file,
        name              => $file,
        from              => 'User',
        is_custom_defined => '1',
        version           => $ORCA_SLICER_VERSION
    );

    # Translate and convert speed settings because Super/PrusaSlicer allow
    # percent-based speeds where OrcaSlicer requires absolute values
    foreach my $parameter (@speed_sequence) {
        my $new_value = $superslicer_ini->{_}->{$parameter} // undef;

        if ( $parameter =~ /^(external_perimeter_speed|first_layer_speed)$/ ) {
            $new_value =
              percent_to_mm( $superslicer_ini->{_}->{'perimeter_speed'},
                undef, $new_value );
        }
        elsif ( $parameter eq 'top_solid_infill_speed' ) {
            $new_value =
              percent_to_mm( $new_hash{'internal_solid_infill_speed'},
                undef, $new_value );
        }
        elsif ( $parameter eq 'support_material_interface_speed' ) {
            $new_value =
              percent_to_mm( $superslicer_ini->{_}->{'support_material_speed'},
                undef, $new_value );
        }
        elsif ( $parameter eq 'first_layer_infill_speed' ) {
            if ( $slicer_flavor eq 'PrusaSlicer' ) {
                $new_value =
                  percent_to_mm( $superslicer_ini->{_}->{'infill_speed'},
                    undef, $superslicer_ini->{_}->{'first_layer_speed'} );
            }
            else {
                $new_value =
                  percent_to_mm( $superslicer_ini->{_}->{'infill_speed'},
                    undef, $new_value );
            }
        }

        # PrusaSlicer calculates solid infill speed as a percentage of sparse
        elsif ($slicer_flavor eq 'PrusaSlicer'
            && $parameter eq 'solid_infill_speed' )
        {
            $new_value = percent_to_mm( $superslicer_ini->{_}->{'infill_speed'},
                undef, $new_value );
        }

        # SuperSlicer has a "default_speed" parameter that PrusaSlivcer doesn't,
        # and a lot of percentages are based on that default
        elsif ( $slicer_flavor eq 'SuperSlicer' ) {
            my $default_speed = $superslicer_ini->{_}->{'default_speed'};
            my @default_percent_params =
              qw(perimeter_speed solid_infill_speed support_material_speed bridge_speed);
            if ( grep { $_ eq $parameter } @default_percent_params ) {
                $new_value = percent_to_mm( $default_speed, undef, $new_value );
            }
            elsif ( $parameter eq 'infill_speed' ) {
                $new_value =
                  percent_to_mm( $new_hash{'internal_solid_infill_speed'},
                    undef, $new_value );
            }
            elsif ( $parameter =~ /^(small_perimeter_speed|gap_fill_speed)$/ ) {
                $new_value = percent_to_mm( $new_hash{'sparse_infill_speed'},
                    undef, $new_value );
            }
        }

        next if ( !defined $new_value );

        # Limit mm/s values to one decimal place so OrcaSlicer doesn't choke
        if ( is_decimal($new_value) ) {
            $new_value = sprintf( "%.1f", $new_value );
        }
        $new_value =~ s/\.?0+$//;    # Chop trailing zeroes
        $new_hash{ $speed_params{$parameter} } = "" . $new_value;
    }

    # Translate the Dynamic Overhangs thresholds
    my $enable_dynamic_overhang_speeds =
      !!$superslicer_ini->{_}->{'enable_dynamic_overhang_speeds'};
    $new_hash{'enable_overhang_speed'} =
      $enable_dynamic_overhang_speeds ? '1' : '0';
    if ($enable_dynamic_overhang_speeds) {
        my @speeds =
          split( ',', $superslicer_ini->{_}->{'dynamic_overhang_speeds'} );
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

    # Construct the output filename
    my $output_file = $output_directory . $file . ".json";

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

    print "Translated '$input_file' to '$output_file'.\n";
}
