from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from ament_index_python.packages import get_package_share_directory
import os

def generate_launch_description():
    odrive_s1_share = get_package_share_directory('odrive_s1')
    odrive_s1_launch = os.path.join(odrive_s1_share, 'node.launch.py')

    return LaunchDescription([
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(odrive_s1_launch)
        ),
    ])