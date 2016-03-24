include(CMakeParseArguments)

include(cmake/boost)
include(cmake/list_dependencies)
include(cmake/gmock)

add_library(ctti INTERFACE)
target_include_directories(ctti INTERFACE ${CMAKE_SOURCE_DIR}/3rdParty/ctti/include)
target_compile_definitions(ctti INTERFACE
    $<$<CXX_COMPILER_ID:MSVC>: -DCTTI_STRING_MAX_LENGTH=512>
    $<$<OR:$<CXX_COMPILER_ID:gcc>,$<CXX_COMPILER_ID:clang>>: -DCTTI_STRING_MAX_LENGTH=1024>
)

set(NAMESPACE_SEPARATOR "-")

function(add_run_target NAME TARGET_TYPE)
    set(global-run-test-all run${NAMESPACE_SEPARATOR}tests${NAMESPACE_SEPARATOR}all)
    set(global-run-all run${NAMESPACE_SEPARATOR}all)

    if(NOT (TARGET ${global-run-test-all}))
        add_custom_target(${global-run-test-all})
    endif()
    if(NOT (TARGET ${global-run-all}))
        add_custom_target(${global-run-all})
    endif()

    if(TARGET_TYPE MATCHES "UNIT_TEST")
        set(global ${global-run-test-all})
    else()
        set(global ${global-run-all})
    endif()

    if(ARGS_NAMESPACE)
        set(all-target run${NAMESPACE_SEPARATOR}${ARGS_NAMESPACE}${NAMESPACE_SEPARATOR}all)
        set(run-target run${NAMESPACE_SEPARATOR}${NAME})
    else()
        if(TARGET_TYPE MATCHES "UNIT_TEST")
            set(all-target ${global-run-test-all})
        else()
            set(all-target ${global-run-all})
        endif()
    endif()

    set(run-target run${NAMESPACE_SEPARATOR}${NAME})

    # Create custom target to run the executable/test
    add_custom_target(${run-target}
        COMMAND ${NAME} ${ARGS_RUN_ARGS}
        DEPENDS ${NAME}
        COMMENT "Running ${NAME}..."
        VERBATIM
    )

    # Add the run command to the run-all target
    if(NOT ARGS_EXCLUDE_FROM_RUN_ALL)
        if(NOT (TARGET ${all-target}))
            add_custom_target(${all-target})
        endif()

        add_dependencies(${all-target} ${run-target})

        # group run-all target should be run by global run-all
        if(NOT (all-target STREQUAL global))
            add_dependencies(${global} ${all-target})
        endif()
    endif()
endfunction()

# From https://software.lanl.gov/MeshTools/trac/browser/cmake/modules/ParseLibraryList.cmake
function(parse_library_list LIBRARIES)
    foreach( item ${LIBRARIES} )
        if( ${item} MATCHES debug     OR 
            ${item} MATCHES optimized OR 
            ${item} MATCHES general )

            if( ${item} STREQUAL "debug" )
                set( mylist "_debug_libs" )
            elseif( ${item} STREQUAL "optimized" )
                set( mylist "_opt_libs" )
            elseif( ${item} STREQUAL "general" )
                set( mylist "_gen_libs" )
            endif()
      else()
          list( APPEND ${mylist} ${item} )
      endif()
    endforeach()

    set(DEBUG_LIBS     ${_debug_libs}     PARENT_SCOPE)
    set(OPTIMIZED_LIBS ${_optimized_libs} PARENT_SCOPE)
    set(GENERAL_LIBS   ${_gen_libs}       PARENT_SCOPE)
endfunction()

function(handle_windows_dlls ROOT_TARGET TARGET)
    if((NOT WIN32) OR (NOT (TARGET ${TARGET})))
        return()
    endif()
    get_target_property(target_type ${TARGET} TYPE)
    get_target_property(root_target_type ${ROOT_TARGET} TYPE)
    if((target_type STREQUAL INTERFACE_LIBRARY) OR 
       (NOT (root_target_type STREQUAL EXECUTABLE)))
        return()
    endif()
    get_target_property(dependencies ${TARGET} LINK_LIBRARIES)
    if(NOT dependencies)
        return()
    endif()

    message(STATUS " => dlls of target '${TARGET}' for target '${ROOT_TARGET}'")

    set(dest_directory $<TARGET_FILE_DIR:${ROOT_TARGET}>)

    foreach(lib ${dependencies})
        if(TARGET ${lib})
            if(NOT (lib STREQUAL TARGET))
                get_target_property(target_type ${lib} TYPE)
                if(target_type STREQUAL SHARED_LIBRARY)
                    set(dllfile $<TARGET_FILE_DIR:${lib}>/$<TARGET_FILE_NAME:${lib}>)
                endif()
            endif()
        elseif(lib MATCHES ".+\\.dll")
            set(dllfile "${lib}")
        endif()

        if(SIPLASPLAS_VERBOSE_CONFIG)
            set(log COMMAND ${CMAKE_COMMAND} -E echo " - ${dllfile}")
        endif()

        if(dllfile)
            list(APPEND copy_command
                ${log}
                COMMAND ${CMAKE_COMMAND} -E copy 
                    \"${dllfile}\" 
                    \"${dest_directory}\"
            )
        endif()
    endforeach()

    if(copy_command)
        add_custom_command(TARGET ${ROOT_TARGET} POST_BUILD
            ${copy_command}
            COMMENT "Copying dll dependencies of target ${TARGET}..."
        )
    endif()

    foreach(dep ${dependencies})
        handle_windows_dlls(${ROOT_TARGET} "${dep}")
    endforeach()
endfunction()

function(add_siplasplas_target NAME TARGET_TYPE)
    cmake_parse_arguments(ARGS
        "EXCLUDE_FROM_RUN_ALL;STATIC;SHARED;INSTALL;DEFAULT_TEST_MAIN"
        "BOOST_VERSION;NAMESPACE"
        "SOURCES;INCLUDE_DIRS;COMPILE_OPTIONS;LINK_OPTIONS;DEPENDS;BOOST_COMPONENTS;LINK_LIBS;RUN_ARGS"
        ${ARGN}
    )

    if(ARGS_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "Unparsed arguments: ${ARGS_UNPARSED_ARGUMENTS}")
    endif()

    if(ARGS_NAMESPACE)
        string(REGEX REPLACE ";" "${NAMESPACE_SEPARATOR}" ARGS_NAMESPACE "${ARGS_NAMESPACE}")
        set(NAME ${ARGS_NAMESPACE}${NAMESPACE_SEPARATOR}${NAME})
    endif()

    function(set_flags)
        if(NOT MSVC)
            # gtest needs fileno() function at file gtest/include/gtest/internal/gtest-port.h,
            # but is considered an extension in cygwin GCC setup. Use GNU extensions.
            # See http://stackoverflow.com/questions/18784112/googletest-1-6-with-cygwin-1-7-compile-error-fileno-was-not-declared-in-this
            if(CYGWIN AND (TARGET_TYPE MATCHES "UNIT_TEST"))
                set(STD_CXX gnu++14)
            else()
                set(STD_CXX c++14)
            endif()

            set(common_options -std=${STD_CXX} -Wall -pedantic -DCTTI_STRING_MAX_LENGTH=1024 -ftemplate-depth-1024)
            set(debug_options -O0 -g3)
            set(release_options -O3 -g0)
        endif()

        target_compile_options(${NAME} PRIVATE
            ${common_options}
            $<$<CONFIG:Debug>:${debug_options}>
            $<$<CONFIG:Release>:${release_options}>
            ${ARGS_COMPILE_OPTIONS}
        )

        set_property(TARGET ${NAME} APPEND PROPERTY LINK_FLAGS ${ARGS_LINK_OPTIONS})
    endfunction()

    if(ARGS_BOOST_COMPONENTS)
        if(NOT ARGS_BOOST_VERSION)
            set(ARGS_BOOST_VERSION 1.60.0)
        endif()

        bii_find_boost(VERSION ${ARGS_BOOST_VERSION} REQUIRED)

        foreach(component ${ARGS_BOOST_COMPONENTS})
            list(APPEND boost_targets Boost_${component}_TARGET)
        endforeach()
    endif()

    list(APPEND link_libraries ${ARGS_DEPENDS} ${boost_targets} ${ARGS_LINK_LIBS})

    if(TARGET_TYPE STREQUAL "HEADER_ONLY_LIBRARY")
        add_library(${NAME} INTERFACE)
        set(linking INTERFACE)
    elseif(TARGET_TYPE STREQUAL "LIBRARY")
        if(SIPLASPLAS_LIBRARIES_STATIC)
            set(link STATIC)
        else()
            set(link SHARED)
        endif()

        if(ARGS_STATIC)
            set(link STATIC)
        endif()
        if(ARGS_SHARED)
            set(link SHARED)
        endif()

        add_library(${NAME} ${link} ${ARGS_SOURCES})

        # Compute the include directory of the given target
        set(ROOT_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/include/siplasplas")
        set(ROOT_SRC_DIR "${CMAKE_SOURCE_DIR}/src")
        file(RELATIVE_PATH current_relative_path "${ROOT_SRC_DIR}" "${CMAKE_CURRENT_LIST_DIR}")
        set(current_includedir "${ROOT_INCLUDE_DIR}/${current_relative_path}")

        # Add current include dir so we can just do '#include "foo.hpp"' in foo.cpp
        target_include_directories(${NAME} PUBLIC "${current_includedir}")

        set_flags()
        set(linking PUBLIC)
    else()
        # Create the executable
        add_executable(${NAME} ${ARGS_SOURCES})

        if(TARGET_TYPE STREQUAL "UNIT_TEST")
            if(NOT ARGS_GMOCK_VERSION)
                set(ARGS_GMOCK_VERSION 1.57.0)
            endif()

            install_gtestgmock(VERSION ${ARGS_GMOCK_VERSION})

            # gmock is linked against tests by default,
            # gmock default main if requested in settings
            target_link_libraries(${NAME} PRIVATE
                ${GMOCK_LIB_TARGET}
                $<$<BOOL:ARGS_DEFAULT_TEST_MAIN>:${GMOCK_MAIN_TARGET}>
            )
        endif()

        add_run_target(${NAME} ${TARGET_TYPE})
        set_flags()
        set(linking PRIVATE)
    endif()
    
    target_link_libraries(${NAME} ${linking} ${link_libraries})
    handle_windows_dlls(${NAME} ${NAME})    

    target_include_directories(${NAME} ${linking}
        ${CMAKE_SOURCE_DIR}/include
        ${ARGS_INCLUDE_DIRS}
    )

    string(REGEX REPLACE "_" " " TARGET_TYPE "${TARGET_TYPE}")
    message(STATUS "SIPLASPLAS ${TARGET_TYPE} ${NAME}")

    function(print_args var)
        string(REGEX REPLACE "ARGS_(.+)" "\\1" varname "${var}")
        string(TOLOWER "${varname}" varname)
        string(REGEX REPLACE "_" " " varname "${varname}")

        if(${var})
            message(":: ${varname}:")

            foreach(elem ${${var}})
                message("  - ${elem}")
            endforeach()
        else()
            message(":: No ${varname}")
        endif()
    endfunction()

    if(SIPLASPLAS_VERBOSE_CONFIG)
        print_args(ARGS_DEPENDS)
        print_args(ARGS_LINK_LIBS)
        print_args(ARGS_BOOST_COMPONENTS)
        print_args(ARGS_SOURCES)
        print_args(ARGS_INCLUDE_DIRS)

        if(link)
            message(":: Link: ${link}")
        endif()
    endif()
endfunction()

function(add_siplasplas_executable NAME)
    add_siplasplas_target("${NAME}" EXECUTABLE ${ARGN})
endfunction()

function(add_siplasplas_library NAME)
    add_siplasplas_target("${NAME}" LIBRARY ${ARGN})
endfunction()

function(add_siplasplas_header_only_library NAME)
    add_siplasplas_target("${NAME}" HEADER_ONLY_LIBRARY ${ARGN})
endfunction()

function(add_siplasplas_test NAME)
    add_siplasplas_target("${NAME}" UNIT_TEST ${ARGN})
endfunction()
