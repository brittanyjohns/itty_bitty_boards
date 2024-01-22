const HOST_URL = process.env.REACT_APP_HOST_URL || "192.168.254.1";
// const HOST_URL = process.env.REACT_APP_HOST_URL || "localhost";


export const API_URL = `http://${HOST_URL}:3000/api/`;
export interface Board {
    id: string;
    name: string;
    user_id: string;
  }

export interface BoardWithImages extends Board {
    images: ImageItem[];
  }
  
export interface ImageItem {
    image_url: string;
    id: string;
    label: string;
    category: string;
  }
