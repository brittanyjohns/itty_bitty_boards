import { StyleSheet, SafeAreaView, View } from "react-native";
import Board from "../../components/Board";
import { BoardScreen } from "../../screens/BoardScreen";
import { Headline, Provider as PaperProvider } from "react-native-paper";
import { BoardsScreen } from "../../screens/BoardsScreen";
import BottomNav from "../../components/BottomNav";
import { Link, useRouter } from "expo-router";

export default function Page() {
  return (
    <PaperProvider>
      <SafeAreaView style={styles.container}>
        <Headline style={styles.heading}>Boards</Headline>
        <View>
          <BoardsScreen />
          <BottomNav />
        </View>
      </SafeAreaView>
    </PaperProvider>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    padding: 24,
  },
  main: {
    flex: 1,
    justifyContent: "center",
    maxWidth: 960,
    marginHorizontal: "auto",
  },
  title: {
    fontSize: 64,
    fontWeight: "bold",
  },
  heading: {
    fontSize: 48,
    fontWeight: "bold",
    color: "#38434D",
  },
  subtitle: {
    fontSize: 36,
    color: "#38434D",
  },
});
