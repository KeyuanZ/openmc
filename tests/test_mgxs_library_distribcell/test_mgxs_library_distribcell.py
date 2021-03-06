#!/usr/bin/env python

import os
import sys
import glob
import hashlib
sys.path.insert(0, os.pardir)
from testing_harness import PyAPITestHarness
import openmc
import openmc.mgxs


class MGXSTestHarness(PyAPITestHarness):
    def _build_inputs(self):
        # Generate inputs using parent class routine
        super(MGXSTestHarness, self)._build_inputs()

        # Initialize a one-group structure
        energy_groups = openmc.mgxs.EnergyGroups(group_edges=[0, 20.])

        # Initialize MGXS Library for a few cross section types
        # for one material-filled cell in the geometry
        self.mgxs_lib = openmc.mgxs.Library(self._input_set.geometry)
        self.mgxs_lib.by_nuclide = False
        # Test all MGXS types
        self.mgxs_lib.mgxs_types = openmc.mgxs.MGXS_TYPES
        self.mgxs_lib.energy_groups = energy_groups
        self.mgxs_lib.legendre_order = 3
        self.mgxs_lib.domain_type = 'distribcell'
        material_cells = self.mgxs_lib.openmc_geometry.get_all_material_cells()
        self.mgxs_lib.domains = [material_cells[-1]]
        self.mgxs_lib.build_library()

        # Initialize a tallies file
        self._input_set.tallies = openmc.Tallies()
        self.mgxs_lib.add_to_tallies_file(self._input_set.tallies, merge=False)
        self._input_set.tallies.export_to_xml()

    def _get_results(self, hash_output=False):
        """Digest info in the statepoint and return as a string."""

        # Read the statepoint file.
        statepoint = glob.glob(os.path.join(os.getcwd(), self._sp_name))[0]
        sp = openmc.StatePoint(statepoint)

        # Load the MGXS library from the statepoint
        self.mgxs_lib.load_from_statepoint(sp)

        # Average the MGXS across distribcell subdomains
        avg_lib = self.mgxs_lib.get_subdomain_avg_library()

        # Build a string from Pandas Dataframe for each 1-group MGXS
        outstr = ''
        for domain in avg_lib.domains:
            for mgxs_type in avg_lib.mgxs_types:
                mgxs = avg_lib.get_mgxs(domain, mgxs_type)
                df = mgxs.get_pandas_dataframe()
                outstr += df.to_string() + '\n'

        # Hash the results if necessary
        if hash_output:
            sha512 = hashlib.sha512()
            sha512.update(outstr.encode('utf-8'))
            outstr = sha512.hexdigest()

        return outstr

    def _cleanup(self):
        super(MGXSTestHarness, self)._cleanup()
        f = os.path.join(os.getcwd(), 'tallies.xml')
        if os.path.exists(f): os.remove(f)


if __name__ == '__main__':
    harness = MGXSTestHarness('statepoint.10.*', True)
    harness.main()
