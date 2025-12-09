import json
from launch import LaunchDescription
from launch_ros.actions import Node

def generate_launch_description():
    parameters = json.loads('{"joint":"69379550f668abc29b4451c7","control_mode":"position","limit.lower_position":0,"limit.upper_position":360,"limit.position_step":1,"limit.max_effort":10,"limit.effort_step":null,"limit.max_velocity":35,"limit.velocity_step":0}')
    configuration = json.loads('{"namespace":"/robot/base","rate_hz":150,"lifecycle":true}')
    inbound_connections = json.loads('[]')
    outbound_connections = json.loads('[]')
    env = {
        "POLYFLOW_NODE_ID": "69388036f668abc29b445500",
        "POLYFLOW_PARAMETERS": json.dumps(parameters),
        "POLYFLOW_CONFIGURATION": json.dumps(configuration),
        "POLYFLOW_INBOUND_CONNECTIONS": json.dumps(inbound_connections),
        "POLYFLOW_OUTBOUND_CONNECTIONS": json.dumps(outbound_connections),
    }

    return LaunchDescription([
        Node(
            package="odrive_s1",
            executable="odrive_s1_node",
            name="odrive_s1_node",
            output="screen",
            additional_env=env
        )
    ])