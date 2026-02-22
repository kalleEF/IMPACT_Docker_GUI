# Known bugs and problems with the GUI

- On local containers committing in Git does not work currently. However, committing and pushing detected changes after the container exited works fine. 

- If the folder paths from the sim_design_local are set to ...output_local and ...synthpop_local then the container mounts these to outputs and synthpop which duplicates them inside the container.