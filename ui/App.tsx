import * as React from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { createStackNavigator } from '@react-navigation/stack';
import { BoardsScreen } from './screens/BoardsScreen';
import { BoardDetailScreen } from './screens/BoardDetailScreen';
const Stack = createStackNavigator();

function App() {
  return (
    <NavigationContainer>
      <Stack.Navigator initialRouteName="Boards">
        <Stack.Screen name="Boards" component={BoardsScreen} />
        <Stack.Screen name="BoardDetail" component={BoardDetailScreen} />
        {/* You can add more screens here */}
      </Stack.Navigator>
    </NavigationContainer>
  );
}

export default App;
