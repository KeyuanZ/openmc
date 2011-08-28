module input_old

  use constants
  use datatypes,        only: dict_create, dict_add_key, dict_get_key,         &
                              dict_has_key, dict_keys
  use datatypes_header, only: DictionaryII, ListKeyValueII, ListKeyValueCI
  use geometry_header,  only: Cell, Surface, Universe, BASE_UNIVERSE
  use fileio,           only: get_next_line
  use global
  use error,            only: fatal_error
  use output,           only: message
  use string,           only: lower_case, is_number, str_to_int, int_to_str,   &
                              str_to_real

  implicit none

  type(DictionaryII), pointer :: & ! used to count how many cells each
       & ucount_dict => null(),  & ! universe contains
       & bc_dict => null()         ! store boundary conditions

  integer, allocatable :: index_cell_in_univ(:)

contains

!===============================================================================
! READ_COUNT makes a first pass through the input file to determine how many
! cells, universes, surfaces, materials, sources, etc there are in the problem.
!===============================================================================

  subroutine read_count(filename)
    
    character(*), intent(in) :: filename

    integer                 :: in = 7           ! unit # for input file
    integer                 :: index            ! index in universes array
    integer                 :: ioError          ! error status for file access
    integer                 :: n                ! number of words on a line
    integer                 :: count            ! number of cells in a universe
    integer                 :: universe_num     ! user-specified universe #
    character(MAX_LINE_LEN) :: msg              ! output/error message
    character(MAX_WORD_LEN) :: words(MAX_WORDS) ! words on a line
    type(ListKeyValueII), pointer :: key_list => null()
    type(Universe),       pointer :: univ => null()

    msg = "First pass through input file..."
    call message(msg, 5)

    n_cells     = 0
    n_universes = 0
    n_surfaces  = 0
    n_materials = 0
    n_tallies   = 0

    call dict_create(ucount_dict)
    call dict_create(universe_dict)
    call dict_create(lattice_dict)

    open(FILE=filename, UNIT=in, STATUS='old', & 
         & ACTION='read', IOSTAT=ioError)
    if (ioError /= 0) then
       msg = "Error while opening file: " // filename
       call fatal_error(msg)
    end if

    do
       call get_next_line(in, words, n, ioError)
       if (ioError /= 0) exit
       if (n == 0) cycle

       select case (trim(words(1)))
       case ('cell')
          n_cells = n_cells + 1
          
          ! For cells, we also need to check if there's a new universe -- also
          ! for every cell add 1 to the count of cells for the specified
          ! universe
          universe_num = str_to_int(words(3))
          if (.not. dict_has_key(ucount_dict, universe_num)) then
             n_universes = n_universes + 1
             count = 1
             call dict_add_key(universe_dict, universe_num, n_universes)
          else
             count = 1 + dict_get_key(ucount_dict, universe_num)
          end if
          call dict_add_key(ucount_dict, universe_num, count)

       case ('surface')
          n_surfaces = n_surfaces + 1
       case ('material') 
          n_materials = n_materials + 1
       case ('tally')
          n_tallies = n_tallies + 1
       case ('lattice')
          n_lattices = n_lattices + 1

          ! For lattices, we also need to check if there's a new universe --
          ! also for every cell add 1 to the count of cells for the specified
          ! universe
          universe_num = str_to_int(words(2))
          call dict_add_key(lattice_dict, universe_num, n_lattices)

       end select
    end do

    ! Check to make sure there are cells, surface, and materials defined for the
    ! problem
    if (n_cells == 0) then
       msg = "No cells specified!"
       close(UNIT=in)
       call fatal_error(msg)
    elseif (n_surfaces == 0) then
       msg = "No surfaces specified!"
       close(UNIT=in)
       call fatal_error(msg)
    elseif (n_materials == 0) then
       msg = "No materials specified!"
       close(UNIT=in)
       call fatal_error(msg)
    end if

    close(UNIT=in)

    ! Allocate arrays for cells, surfaces, etc.
    allocate(cells(n_cells))
    allocate(universes(n_universes))
    allocate(lattices(n_lattices))
    allocate(surfaces(n_surfaces))
    allocate(materials(n_materials))
    allocate(tallies(n_tallies))

    ! Also allocate a list for keeping track of where cells have been assigned
    ! in each universe
    allocate(index_cell_in_univ(n_universes))
    index_cell_in_univ = 0

    ! Set up dictionaries
    call dict_create(cell_dict)
    call dict_create(surface_dict)
    call dict_create(bc_dict)
    call dict_create(material_dict)
    call dict_create(tally_dict)

    ! We also need to allocate the cell count lists for each universe. The logic
    ! for this is a little more convoluted. In universe_dict, the (key,value)
    ! pairs are the uid of the universe and the index in the array. In
    ! ucount_dict, it's the uid of the universe and the number of cells.

    key_list => dict_keys(universe_dict)
    do while (associated(key_list))
       ! find index of universe in universes array
       index = key_list%data%value
       univ => universes(index)
       univ % uid = key_list%data%key

       ! check for lowest level universe
       if (univ % uid == 0) BASE_UNIVERSE = index
       
       ! find cell count for this universe
       count = dict_get_key(ucount_dict, key_list%data%key)

       ! allocate cell list for universe
       allocate(univ % cells(count))
       univ % n_cells = count
       
       ! move to next universe
       key_list => key_list%next
    end do

  end subroutine read_count

!===============================================================================
! READ_INPUT takes a second pass through the input file and parses all the data
! on each line, calling the appropriate subroutine for each type of data item.
!===============================================================================

  subroutine read_input(filename)

    character(*), intent(in) :: filename

    integer :: in = 7                  ! unit # for input file
    integer :: ioError                 ! error status for file access
    integer :: n                       ! number of words on a line
    integer :: index_cell              ! index in cells array
    integer :: index_universe          ! index in universes array
    integer :: index_surface           ! index in surfaces array
    integer :: index_lattice           ! index in lattices array
    integer :: index_material          ! index in materials array
    integer :: index_source            ! index in source array (?)
    integer :: index_tally             ! index in tally array
    character(MAX_LINE_LEN) :: msg              ! output/error message
    character(MAX_WORD_LEN) :: words(MAX_WORDS) ! words on a single line

    msg = "Second pass through input file..."
    call message(msg, 5)

    index_cell     = 0
    index_universe = 0
    index_surface  = 0
    index_lattice  = 0
    index_material = 0
    index_tally    = 0
    index_source   = 0

    open(FILE=filename, UNIT=in, STATUS='old', & 
         & ACTION='read', IOSTAT=ioError)
    if (ioError /= 0) then
       msg = "Error while opening file: " // filename
       call fatal_error(msg)
    end if

    do
       call get_next_line(in, words, n, ioError)
       if (ioError /= 0) exit

       ! skip comments
       if (n==0 .or. words(1)(1:1) == '#') cycle

       select case (trim(words(1)))
       case ('cell')
          ! Read cell entry
          index_cell = index_cell + 1
          call read_cell(index_cell, words, n)
          
       case ('surface')
          ! Read surface entry
          index_surface = index_surface + 1
          call read_surface(index_surface, words, n)

       case ('bc')
          ! Read boundary condition entry
          call read_bc(words, n)

       case ('lattice')
          ! Read lattice entry
          index_lattice = index_lattice + 1
          call read_lattice(index_lattice, words, n)

       case ('material')
          ! Read material entry
          index_material = index_material + 1
          call read_material(index_material, words, n)

       case ('tally')
          ! Read tally entry
          index_tally = index_tally + 1
          call read_tally(index_tally, words, n)

       case ('source')
          call read_source(words, n)

       case ('criticality')
          call read_criticality(words, n)

       case ('xs_data')
          path_xsdata = words(2)

       case ('verbosity')
          verbosity = str_to_int(words(2))
          if (verbosity == ERROR_INT) then
             msg = "Invalid verbosity: " // trim(words(2))
             call fatal_error(msg)
          end if

       case default
          ! do nothing
       end select

    end do

    ! deallocate array
    deallocate(index_cell_in_univ)

    close(UNIT=in)

  end subroutine read_input

!===============================================================================
! READ_CELL parses the data on a cell card.
!===============================================================================

  subroutine read_cell(index, words, n_words)

    integer,      intent(in) :: index          ! index in cells array
    integer,      intent(in) :: n_words        ! number of words
    character(*), intent(in) :: words(n_words) ! words on cell card entry

    integer                 :: i            ! index for surface list in a cell
    integer                 :: universe_num ! user-specified universe number
    integer                 :: n_surfaces   ! number of surfaces in a cell
    character(MAX_LINE_LEN) :: msg          ! output/error message
    character(MAX_WORD_LEN) :: word         ! single word
    type(Cell), pointer     :: c => null()

    c => cells(index)

    ! Read cell identifier
    c % uid = str_to_int(words(2))
    if (c % uid == ERROR_INT) then
       msg = "Invalid cell name: " // trim(words(2))
       call fatal_error(msg)
    end if
    call dict_add_key(cell_dict, c%uid, index)
 
    ! Read cell universe
    universe_num = str_to_int(words(3))
    if (universe_num == ERROR_INT) then
       msg = "Invalid universe: " // trim(words(3))
       call fatal_error(msg)
    end if
    c % universe = dict_get_key(universe_dict, universe_num)

    ! Read cell material
    if (trim(words(4)) == 'fill') then
       c % material = 0
       n_surfaces   = n_words - 5

       ! find universe
       universe_num = str_to_int(words(5))
       if (universe_num == ERROR_INT) then
          msg = "Invalid universe fill: " // trim(words(5))
          call fatal_error(msg)
       end if

       ! check whether universe or lattice
       if (dict_has_key(universe_dict, universe_num)) then
          c % type = CELL_FILL
          c % fill = dict_get_key(universe_dict, universe_num)
       elseif (dict_has_key(lattice_dict, universe_num)) then
          c % type = CELL_LATTICE
          c % fill = dict_get_key(lattice_dict, universe_num)
       end if
    else
       c % type     = CELL_NORMAL
       c % material = str_to_int(words(4))
       c % fill     = 0
       if (c % material == ERROR_INT) then
          msg = "Invalid material number: " // trim(words(4))
          call fatal_error(msg)
       end if
       n_surfaces = n_words - 4
    end if

    ! Assign number of items
    c % n_surfaces = n_surfaces

    ! Read list of surfaces
    allocate(c%surfaces(n_surfaces))
    do i = 1, n_surfaces
       word = words(i+n_words-n_surfaces)
       if (word(1:1) == '(') then
          c % surfaces(i) = OP_LEFT_PAREN
       elseif (word(1:1) == ')') then
          c % surfaces(i) = OP_RIGHT_PAREN
       elseif (word(1:1) == ':') then
          c % surfaces(i) = OP_UNION
       elseif (word(1:1) == '#') then
          c % surfaces(i) = OP_DIFFERENCE
       else
          c % surfaces(i) = str_to_int(word)
       end if
    end do

    ! Add cell to the cell list in the corresponding universe
    i = c % universe
    index_cell_in_univ(i) = index_cell_in_univ(i) + 1
    universes(i) % cells(index_cell_in_univ(i)) = index

  end subroutine read_cell

!===============================================================================
! READ_SURFACE parses the data on a surface card.
!===============================================================================

  subroutine read_surface(index, words, n_words)

    integer,      intent(in) :: index          ! index in surfaces array
    integer,      intent(in) :: n_words        ! number of words
    character(*), intent(in) :: words(n_words) ! words in surface card entry

    integer                 :: i           ! index for surface coefficients
    integer                 :: coeffs_reqd ! number of coefficients are required
    character(MAX_LINE_LEN) :: msg         ! output/error message
    character(MAX_WORD_LEN) :: word        ! single word
    type(Surface), pointer  :: surf => null()

    surf => surfaces(index)

    ! Read surface identifier
    surf % uid = str_to_int(words(2))
    if (surf % uid == ERROR_INT) then
       msg = "Invalid surface name: " // trim(words(2))
       call fatal_error(msg)
    end if
    call dict_add_key(surface_dict, surf % uid, index)

    ! Read surface type
    word = words(3)
    call lower_case(word)
    select case (trim(word))
       case ('px')
          surf % type = SURF_PX
          coeffs_reqd  = 1
       case ('py')
          surf % type = SURF_PY
          coeffs_reqd  = 1
       case ('pz')
          surf % type = SURF_PZ
          coeffs_reqd  = 1
       case ('plane')
          surf % type = SURF_PLANE
          coeffs_reqd  = 4
       case ('cylx')
          surf % type = SURF_CYL_X
          coeffs_reqd  = 3
       case ('cyly')
          surf % type = SURF_CYL_Y
          coeffs_reqd  = 3
       case ('cylz')
          surf % type = SURF_CYL_Z
          coeffs_reqd  = 3
       case ('sph')
          surf % type = SURF_SPHERE
          coeffs_reqd  = 4
       case ('boxx')
          surf % type = SURF_BOX_X
          coeffs_reqd  = 4
       case ('boxy')
          surf % type = SURF_BOX_Y
          coeffs_reqd  = 4
       case ('boxz')
          surf % type = SURF_BOX_Z
          coeffs_reqd  = 4
       case ('box') 
          surf % type = SURF_BOX
          coeffs_reqd  = 6
       case ('gq')
          surf % type = SURF_GQ
          coeffs_reqd  = 10
       case default
          msg = "Invalid surface type: " // trim(words(3))
          call fatal_error(msg)
    end select

    ! Make sure there are enough coefficients for surface type
    if (n_words-3 < coeffs_reqd) then
       msg = "Not enough coefficients for surface: " // trim(words(2))
       call fatal_error(msg)
    end if
    
    ! Read list of surfaces
    allocate(surf%coeffs(n_words-3))
    do i = 1, n_words-3
       surf % coeffs(i) = str_to_real(words(i+3))
    end do

  end subroutine read_surface

!===============================================================================
! READ_BC creates a dictionary whose (key,value) pairs are the uids of surfaces
! and specified boundary conditions, respectively. This is later used in
! adjust_indices to set the surface boundary conditions.
!===============================================================================

  subroutine read_bc(words, n_words)

    integer,      intent(in) :: n_words        ! number of words
    character(*), intent(in) :: words(n_words) ! words in bc entry

    integer                 :: surface_uid ! User-specified uid of surface
    integer                 :: bc          ! Boundary condition
    character(MAX_WORD_LEN) :: word        ! Boundary condition (in input file)
    character(MAX_LINE_LEN) :: msg         ! Output/error message

    ! Read surface identifier
    surface_uid = str_to_int(words(2))
    if (surface_uid == ERROR_INT) then
       msg = "Invalid surface name: " // trim(words(2))
       call fatal_error(msg)
    end if

    ! Read boundary condition
    word = words(3)
    call lower_case(word)
    select case (trim(word))
    case ('transmit')
       bc = BC_TRANSMIT
    case ('vacuum')
       bc = BC_VACUUM
    case ('reflect')
       bc = BC_REFLECT
    case default
       msg = "Invalid boundary condition: " // trim(words(3))
       call fatal_error(msg)
    end select

    ! Add (uid, bc) to dictionary
    call dict_add_key(bc_dict, surface_uid, bc)

  end subroutine read_bc

!===============================================================================
! READ_LATTICE parses the data on a lattice entry.
!===============================================================================

  subroutine read_lattice(index, words, n_words)

    integer,      intent(in) :: index          ! index in lattices array
    integer,      intent(in) :: n_words        ! number of words
    character(*), intent(in) :: words(n_words) ! words in lattice entry

    integer                 :: universe_num ! user-specified universe number
    integer                 :: n_x          ! number of lattice cells in x direction
    integer                 :: n_y          ! number of lattice cells in y direction
    integer                 :: i,j          ! loop indices for Lattice % universes
    integer                 :: index_word   ! index in words array
    character(MAX_LINE_LEN) :: msg          ! output/error/message
    character(MAX_WORD_LEN) :: word         ! single word
    type(Lattice), pointer  :: lat => null()
    
    lat => lattices(index)

    ! Read lattice universe
    universe_num = str_to_int(words(2))
    if (universe_num == ERROR_INT) then
       msg = "Invalid universe: " // trim(words(2))
       call fatal_error(msg)
    end if
    lat % uid = universe_num

    ! Read lattice type
    word = words(3)
    call lower_case(word)
    select case(trim(word))
    case ('rect')
       lat % type = LATTICE_RECT
    case ('hex')
       lat % type = LATTICE_HEX
    case default
       msg = "Invalid lattice type: " // trim(words(3))
       call fatal_error(msg)
    end select

    ! Read number of lattice cells in each direction
    n_x = str_to_int(words(4))
    n_y = str_to_int(words(5))
    if (n_x == ERROR_INT) then
       msg = "Invalid number of lattice cells in x-direction: " // trim(words(4))
       call fatal_error(msg)
    elseif (n_y == ERROR_INT) then
       msg = "Invalid number of lattice cells in y-direction: " // trim(words(5))
       call fatal_error(msg)
    end if
    lat % n_x = n_x
    lat % n_y = n_y

    ! Read lattice origin coordinates
    lat % x0 = str_to_real(words(6))
    lat % y0 = str_to_real(words(7))

    ! Read lattice cell widths
    lat % width_x = str_to_real(words(8))
    lat % width_y = str_to_real(words(9))

    ! Make sure enough lattice positions specified
    if (n_words - 9 < n_x * n_y) then
       print *, n_words, n_x, n_y
       msg = "Not enough lattice positions specified."
       call fatal_error(msg)
    end if

    ! Read lattice positions
    allocate(lat % element(n_x,n_y))
    do j = 0, n_y - 1
       do i = 1, n_x
          index_word = 9 + j*n_x + i
          universe_num = str_to_int(words(index_word))
          if (universe_num == ERROR_INT) then
             msg = "Invalid universe number: " // trim(words(index_word))
             call fatal_error(msg)
          end if
          lat % element(i, n_y-j) = dict_get_key(universe_dict, universe_num)
       end do
    end do

  end subroutine read_lattice

!===============================================================================
! READ_SOURCE parses the data on a source entry.
!===============================================================================

  subroutine read_source(words, n_words)

    integer,      intent(in) :: n_words        ! number of words
    character(*), intent(in) :: words(n_words) ! words on source entry

    integer                 :: i           ! index in values list
    integer                 :: values_reqd ! # of values required to specify source
    character(MAX_LINE_LEN) :: msg  ! output/error message
    character(MAX_WORD_LEN) :: word ! single word

    ! Read source type
    word = words(2)
    call lower_case(word)
    select case (trim(word))
    case ('box')
       external_source % type = SRC_BOX
       values_reqd = 6
    case default
       msg = "Invalid source type: " // trim(words(2))
       call fatal_error(msg)
    end select

    ! Make sure there are enough values for this source type
    if (n_words-2 < values_reqd) then
       msg = "Not enough values for source of type: " // trim(words(2))
       call fatal_error(msg)
    end if
    
    ! Read values
    allocate(external_source%values(n_words-2))
    do i = 1, n_words-2
       external_source % values(i) = str_to_real(words(i+2))
    end do
    
  end subroutine read_source

!===============================================================================
! READ_TALLY
!===============================================================================

  subroutine read_tally(index, words, n_words)

    integer,      intent(in) :: index          ! index in materials array
    integer,      intent(in) :: n_words        ! number of words
    character(*), intent(in) :: words(n_words) ! words on material entry

    integer :: i  ! index in words array
    integer :: j
    integer :: k
    integer :: count
    integer :: MT
    integer :: cell_uid
    integer :: r_bins, c_bins, e_bins
    real(8) :: E
    character(MAX_WORD_LEN) :: word
    character(MAX_LINE_LEN) :: msg
    type(Tally), pointer :: t => null()

    t => tallies(index)

    ! Read tally identifier
    t % uid = str_to_int(words(2))
    if (t % uid == ERROR_INT) then
       msg = "Invalid tally name: " // trim(words(2))
       call fatal_error(msg)
    end if
    call dict_add_key(tally_dict, t % uid, index)

    i = 3
    do while (i <= n_words)
       word = words(i)
       call lower_case(word)
       
       select case (trim(word))
       case ('reaction')
          ! ====================================================================
          ! READ REACTION LIST

          ! Determine how many reactions are listed
          do j = i+1, n_words
             if (.not. is_number(words(j))) exit
          end do
          count = j - (i+1)

          ! Allocate space to store reactions
          allocate(t % reactions(count))
          
          ! Read reaction MT values
          do j = 1, count
             MT = str_to_int(words(i+j))
             if (MT == ERROR_INT) then
                msg = "Invalid reaction MT on tally: " // int_to_str(t%uid)
                call fatal_error(msg)
             end if
             t % reactions(j) = MT
          end do

          ! Determine whether to sum reactions or individually bin
          if (trim(words(i+count+1)) == 'sum') then
             t % reaction_type = TALLY_SUM
             r_bins = 1
          else
             t % reaction_type = TALLY_BINS
             r_bins = count
          end if

       case ('cell')
          ! ====================================================================
          ! READ CELL LIST

          ! Determine how many reactions are listed
          do j = i+1, n_words
             if (.not. is_number(words(j))) exit
          end do
          count = j - (i+1)

          ! Allocate space to store reactions
          allocate(t % cells(count))
          
          ! Read reaction MT values
          do j = 1, count
             cell_uid = str_to_int(words(i+j))
             if (cell_uid == ERROR_INT) then
                msg = "Invalid cell number on tally: " // int_to_str(t%uid)
                call fatal_error(msg)
             end if
             t % cells(j) = cell_uid
          end do

          ! Determine whether to sum reactions or individually bin
          if (trim(words(i+count+1)) == 'sum') then
             t % cell_type = TALLY_SUM
             c_bins = 1
          else
             t % cell_type = TALLY_BINS
             c_bins = count
          end if

       case ('energy')
          ! ====================================================================
          ! READ ENERGY LIST

          ! Determine how many energies are listed
          do j = i+1, n_words
             if (.not. is_number(words(j)(1:1))) exit
          end do
          count = j - (i+1)

          ! Allocate space to store energies
          allocate(t % energies(count))
          
          ! Read reaction MT values
          do j = 1, count
             E = str_to_real(words(i+j))
             if (E == ERROR_REAL) then
                msg = "Invalid energy on tally: " // int_to_str(t % uid)
                call fatal_error(msg)
             end if
             t % energies(j) = E
          end do

          e_bins = count - 1

       case ('material')
          ! TODO: Add ability to read material lists

       case ('universe')
          ! TODO: Add ability to read universe lists

       case ('lattice')
          ! TODO: Add lattice tally ability

       end select
       
       ! Move index in words forward
       i = i + 1 + count

    end do

    ! allocate tally scores
    allocate(t % score(r_bins, c_bins, e_bins))

    ! initialize tallies
    forall (i=1:r_bins, j=1:c_bins, k=1:e_bins)
       t % score(i,j,k) % n_events = 0
       t % score(i,j,k) % val      = ZERO
       t % score(i,j,k) % val_sq   = ZERO
    end forall

  end subroutine read_tally

!===============================================================================
! READ_MATERIAL parses a material card. Note that atom percents and densities
! are normalized in a separate routine
!===============================================================================

  subroutine read_material(index, words, n_words)

    integer,      intent(in) :: index          ! index in materials array
    integer,      intent(in) :: n_words        ! number of words
    character(*), intent(in) :: words(n_words) ! words on material entry

    integer                 :: i          ! index over nuclides
    integer                 :: n_nuclides ! number of nuclides in material
    character(MAX_LINE_LEN) :: msg        ! output/error message
    type(Material), pointer :: mat => null()

    ! Check for correct number of arguments
    if (mod(n_words,2) == 0 .or. n_words < 5) then
       msg = "Invalid number of arguments for material: " // trim(words(2))
       call fatal_error(msg)
    end if

    ! Determine and set number of nuclides
    n_nuclides = (n_words-3)/2
    mat => materials(index)
    mat % n_nuclides = n_nuclides

    ! Read surface identifier
    mat % uid = str_to_int(words(2))
    if (mat % uid == ERROR_INT) then
       msg = "Invalid surface name: " // trim(words(2))
       call fatal_error(msg)
    end if
    call dict_add_key(material_dict, mat%uid, index)

    ! Read atom density
    mat % atom_density = str_to_real(words(3))

    ! allocate isotope and density list
    allocate(mat%names(n_nuclides))
    allocate(mat%xsdata(n_nuclides))
    allocate(mat%nuclide(n_nuclides))
    allocate(mat%atom_percent(n_nuclides))

    ! read names and percentage
    do i = 1, n_nuclides
       mat % names(i) = words(2*i+2)
       mat % atom_percent(i) = str_to_real(words(2*i+3))
    end do

  end subroutine read_material

!===============================================================================
! READ_CRITICALITY parses the data on a criticality card. This card specifies
! that the problem at hand is a criticality calculation and gives the number of
! cycles, inactive cycles, and particles per cycle.
!===============================================================================

  subroutine read_criticality(words, n_words)

    integer,      intent(in) :: n_words        ! number of words
    character(*), intent(in) :: words(n_words) ! words on criticality card

    character(MAX_LINE_LEN) :: msg ! output/error message

    ! Set problem type to criticality
    problem_type = PROB_CRITICALITY

    ! Read number of cycles
    n_cycles = str_to_int(words(2))
    if (n_cycles == ERROR_INT) then
       msg = "Invalid number of cycles: " // trim(words(2))
       call fatal_error(msg)
    end if

    ! Read number of inactive cycles
    n_inactive = str_to_int(words(3))
    if (n_inactive == ERROR_INT) then
       msg = "Invalid number of inactive cycles: " // trim(words(2))
       call fatal_error(msg)
    end if

    ! Read number of particles
    n_particles = str_to_int(words(4))
    if (n_particles == ERROR_INT) then
       msg = "Invalid number of particles: " // trim(words(2))
       call fatal_error(msg)
    end if

  end subroutine read_criticality

end module input_old