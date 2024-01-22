// app/cemnnoopst / BoardList.js;
import React from "react";
// import { Link } from "expo-router";
import { Link } from "@react-navigation/native";

import { StyleSheet, SafeAreaView, View, Text } from "react-native";

const BoardList = ({ boards }) => {
  return (
    <SafeAreaView>
      <View>
        {boards &&
          boards.map((board) => (
            <View key={board.id}>
              <Link to={{ screen: "BoardDetail", params: { id: board.id } }}>
                {board.name}
              </Link>
            </View>
          ))}
      </View>
    </SafeAreaView>
  );
};

export default BoardList;
